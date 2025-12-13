"""
FUSE filesystem implementation for Ethereum-backed filesystem
"""
import os
import logging
import stat
import time
from typing import Dict, Optional, Tuple, List, Set
from fuse import FuseOSError, Operations, LoggingMixIn
from web3 import Web3

from .rpc_manager import RPCManager
from .contract_manager import ContractManager

logger = logging.getLogger(__name__)

# EntryType enum values from contract
ENTRY_TYPE_FILE = 0
ENTRY_TYPE_DIRECTORY = 1
ENTRY_TYPE_LINK = 2


class EthFS(LoggingMixIn, Operations):
    """
    FUSE filesystem backed by Ethereum smart contract
    Path structure: /CHAIN_ID/ACCOUNT_ADDRESS/path/to/file
    """
    
    def __init__(self, contract_addresses: Dict[int, str]):
        """
        Initialize the filesystem
        
        Args:
            contract_addresses: Dictionary mapping chain_id to contract address
        """
        self.contract_addresses = contract_addresses
        self.rpc_manager = RPCManager()
        
        # Initialize contract managers for each chain
        self.contract_managers: Dict[int, ContractManager] = {}
        for chain_id, address in contract_addresses.items():
            w3 = self.rpc_manager.get_connection(chain_id)
            if w3 is None:
                logger.warning(f"Could not connect to chain {chain_id}, skipping")
                continue
            self.contract_managers[chain_id] = ContractManager(w3, address)
        
        # Cache for directory listings and file metadata
        # Maps (chain_id, account, path) -> entry_info
        self.entry_cache: Dict[Tuple[int, str, str], dict] = {}
        # Maps (chain_id, account) -> Set[storage_slot]
        self.slot_cache: Dict[Tuple[int, str], Set[int]] = {}
        
        # Get current process uid/gid for default permissions
        self.default_uid = os.getuid()
        self.default_gid = os.getgid()
        
        # Build initial cache
        self._refresh_cache()
    
    def _parse_path(self, path: str) -> Tuple[Optional[int], Optional[str], Optional[str]]:
        """
        Parse a path into its components
        
        Returns: (chain_id, account_address, relative_path)
        """
        parts = [p for p in path.split('/') if p]
        
        if len(parts) == 0:
            return (None, None, None)
        
        # First level is chain ID
        try:
            chain_id = int(parts[0])
        except ValueError:
            return (None, None, None)
        
        if len(parts) == 1:
            return (chain_id, None, None)
        
        # Second level is account address
        account = parts[1]
        
        if len(parts) == 2:
            return (chain_id, account, None)
        
        # Rest is the relative path
        relative_path = '/'.join(parts[2:])
        return (chain_id, account, relative_path)
    
    def _refresh_cache(self):
        """Refresh the cache by querying all entries from contracts"""
        self.entry_cache.clear()
        self.slot_cache.clear()
        
        for chain_id, contract_manager in self.contract_managers.items():
            try:
                # Get all storage slots
                slots = contract_manager.contract.functions.getEntries().call()
                
                for slot in slots:
                    try:
                        entry = contract_manager.contract.functions.getEntry(slot).call()
                        entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                        
                        if not exists:
                            continue
                        
                        owner_lower = owner.lower()
                        if (chain_id, owner_lower) not in self.slot_cache:
                            self.slot_cache[(chain_id, owner_lower)] = set()
                        self.slot_cache[(chain_id, owner_lower)].add(slot)
                        
                        # Build path from entry name (which stores the full path)
                        # Both files and directories now store their names
                        if name_bytes:
                            try:
                                full_path = name_bytes.decode('utf-8')
                                # Store entry info with full path
                                self.entry_cache[(chain_id, owner_lower, full_path)] = {
                                    'slot': slot,
                                    'type': entry_type,
                                    'owner': owner,
                                    'size': file_size,
                                    'timestamp': timestamp,
                                    'name': full_path.split('/')[-1] if '/' in full_path else full_path
                                }
                            except UnicodeDecodeError:
                                logger.warning(f"Could not decode name for slot {slot}")
                    except Exception as e:
                        logger.debug(f"Error processing slot {slot} on chain {chain_id}: {e}")
            except Exception as e:
                logger.error(f"Error refreshing cache for chain {chain_id}: {e}")
    
    def _get_entry_info(self, chain_id: int, account: str, path: str) -> Optional[dict]:
        """Get entry information from cache or contract"""
        account_lower = account.lower()
        
        # Check cache first
        if (chain_id, account_lower, path) in self.entry_cache:
            return self.entry_cache[(chain_id, account_lower, path)]
        
        # Try to get from contract
        if chain_id not in self.contract_managers:
            return None
        
        contract_manager = self.contract_managers[chain_id]
        
        # Check if it's a directory by checking if any files start with this path
        # This is a fallback for directories that might not be in cache yet
        if path and not path.endswith('/'):
            # Check if this is a directory
            dir_path = path + '/'
            for (c_id, acc, file_path) in self.entry_cache.keys():
                if c_id == chain_id and acc == account_lower and file_path.startswith(dir_path):
                    return {
                        'type': ENTRY_TYPE_DIRECTORY,
                        'owner': account,
                        'size': 0,
                        'timestamp': int(time.time()),
                        'name': path.split('/')[-1] if '/' in path else path
                    }
        
        # Try to get entry from contract
        try:
            entry = contract_manager.get_entry(account, path)
            if entry:
                entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                if exists:
                    # Find the slot
                    slot = contract_manager._find_slot_by_path(account, path)
                    info = {
                        'slot': slot,
                        'type': entry_type,
                        'owner': owner,
                        'size': file_size,
                        'timestamp': timestamp,
                        'name': path.split('/')[-1] if '/' in path else path
                    }
                    # Cache it
                    self.entry_cache[(chain_id, account_lower, path)] = info
                    return info
        except Exception as e:
            logger.debug(f"Error getting entry for {path}: {e}")
        
        return None
    
    def _get_contract_manager(self, chain_id: int, account: str) -> Optional[ContractManager]:
        """Get contract manager and ensure account is set up"""
        if chain_id not in self.contract_managers:
            return None
        return self.contract_managers[chain_id]
    
    def _list_directory(self, chain_id: int, account: str, path: str) -> List[str]:
        """List directory contents"""
        account_lower = account.lower()
        entries = set()
        
        # If path is empty, list all top-level files/directories for this account
        if not path:
            for (c_id, acc, file_path), entry_info in self.entry_cache.items():
                if c_id == chain_id :
                    # Get the first component of the path
                    if '/' in file_path:
                        first_part = file_path.split('/')[0]
                        entries.add(first_part)
                    else:
                        entries.add(file_path)
        else:
            # List files and directories in this directory
            prefix = path + '/'
            for (c_id, acc, file_path), entry_info in self.entry_cache.items():
                if c_id == chain_id and file_path.startswith(prefix):
                    # Get the next component after the prefix
                    remaining = file_path[len(prefix):]
                    if remaining:
                        next_part = remaining.split('/')[0]
                        entries.add(next_part)
        
        return sorted(list(entries))
    
    # FUSE Operations
    
    def access(self, path: str, mode: int) -> int:
        """Check file access permissions"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None:
            # Root directory - always accessible
            return 0
        
        if account is None:
            # Chain directory - always accessible
            return 0
        
        if rel_path is None:
            # Account directory - always accessible
            return 0
        
        # Check if entry exists
        entry_info = self._get_entry_info(chain_id, account, rel_path)
        if entry_info is None:
            raise FuseOSError(os.ENOENT)
        
        return 0
    
    def chmod(self, path: str, mode: int) -> int:
        """Change file mode (not supported - permissions are on-chain)"""
        # Permissions are managed by the contract owner, not filesystem permissions
        return 0
    
    def chown(self, path: str, uid: int, gid: int) -> int:
        """Change file ownership (not supported - ownership is on-chain)"""
        # Ownership is managed by the contract, not filesystem
        return 0
    
    def create(self, path: str, mode: int, fi=None) -> int:
        """Create a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        # Create empty file
        filename = rel_path.split('/')[-1]
        try:
            success = contract_manager.create_file(rel_path, b'', account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error creating file {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def getattr(self, path: str, fh=None) -> dict:
        """Get file attributes"""
        chain_id, account, rel_path = self._parse_path(path)
        
        # Root directory
        if chain_id is None:
            return {
                'st_mode': stat.S_IFDIR | 0o755,
                'st_nlink': 2,
                'st_size': 0,
                'st_ctime': time.time(),
                'st_mtime': time.time(),
                'st_atime': time.time(),
                'st_uid': self.default_uid,
                'st_gid': self.default_gid,
            }
        
        # Chain directory
        if account is None:
            return {
                'st_mode': stat.S_IFDIR | 0o755,
                'st_nlink': 2,
                'st_size': 0,
                'st_ctime': time.time(),
                'st_mtime': time.time(),
                'st_atime': time.time(),
                'st_uid': self.default_uid,
                'st_gid': self.default_gid,
            }
        
        # Account directory
        if rel_path is None:
            return {
                'st_mode': stat.S_IFDIR | 0o755,
                'st_nlink': 2,
                'st_size': 0,
                'st_ctime': time.time(),
                'st_mtime': time.time(),
                'st_atime': time.time(),
                'st_uid': self.default_uid,
                'st_gid': self.default_gid,
            }
        
        # Get entry info
        entry_info = self._get_entry_info(chain_id, account, rel_path)
        
        if entry_info is None:
            # Check if it's a directory by checking for sub-entries
            # A path is a directory if there are files that start with path + '/'
            account_lower = account.lower()
            dir_path = rel_path + '/' if rel_path else ''
            is_directory = False
            for (c_id, acc, file_path) in self.entry_cache.keys():
                if c_id == chain_id and acc == account_lower:
                    if file_path.startswith(dir_path) and file_path != rel_path:
                        is_directory = True
                        break
            
            if is_directory:
                return {
                    'st_mode': stat.S_IFDIR | 0o755,
                    'st_nlink': 2,
                    'st_size': 0,
                    'st_ctime': time.time(),
                    'st_mtime': time.time(),
                    'st_atime': time.time(),
                    'st_uid': self.default_uid,
                    'st_gid': self.default_gid,
                }
            raise FuseOSError(os.ENOENT)
        
        # Determine file type
        if entry_info['type'] == ENTRY_TYPE_DIRECTORY:
            st_mode = stat.S_IFDIR | 0o755
        else:
            st_mode = stat.S_IFREG | 0o644
        
        return {
            'st_mode': st_mode,
            'st_nlink': 1,
            'st_size': entry_info.get('size', 0),
            'st_ctime': entry_info.get('timestamp', time.time()),
            'st_mtime': entry_info.get('timestamp', time.time()),
            'st_atime': time.time(),
            'st_uid': self.default_uid,
            'st_gid': self.default_gid,
        }
    
    def mkdir(self, path: str, mode: int) -> int:
        """Create a directory"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        try:
            # Create directory (using address(0) for organizational directories)
            success = contract_manager.create_directory(rel_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error creating directory {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def open(self, path: str, flags: int) -> int:
        """Open a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        entry_info = self._get_entry_info(chain_id, account, rel_path)
        if entry_info is None:
            raise FuseOSError(os.ENOENT)
        
        if entry_info['type'] != ENTRY_TYPE_FILE:
            raise FuseOSError(os.EISDIR)
        
        # Return a file handle (we don't need to track it, just return 0)
        return 0
    
    def read(self, path: str, size: int, offset: int, fh) -> bytes:
        """Read from a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        try:
            data = contract_manager.read_file(rel_path, offset, size, account)
            if data is None:
                return b''
            return data
        except Exception as e:
            logger.error(f"Error reading file {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def readdir(self, path: str, fh) -> List[str]:
        """Read directory contents"""
        chain_id, account, rel_path = self._parse_path(path)
        
        # Root directory - list chain IDs
        if chain_id is None:
            return ['.', '..'] + [str(cid) for cid in self.contract_managers.keys()]
        
        # Chain directory - list accounts
        if account is None:
            # Get all unique accounts for this chain
            accounts = set()
            for (c_id, acc, _) in self.entry_cache.keys():
                if c_id == chain_id:
                    accounts.add(acc)
            return ['.', '..'] + sorted(list(accounts))
        
        # Account directory or subdirectory - list files
        if rel_path is None:
            rel_path = ''
        
        entries = self._list_directory(chain_id, account, rel_path)
        return ['.', '..'] + entries
    
    def readlink(self, path: str) -> str:
        """Read symbolic link target"""
        raise FuseOSError(os.EINVAL)
    
    def rename(self, old: str, new: str) -> int:
        """Rename a file or directory"""
        # Not supported - would require updating the contract
        raise FuseOSError(os.ENOSYS)
    
    def rmdir(self, path: str) -> int:
        """Remove a directory"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        # Check if directory is empty
        entries = self._list_directory(chain_id, account, rel_path)
        if entries:
            raise FuseOSError(os.ENOTEMPTY)
        
        try:
            success = contract_manager.delete_entry(rel_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error removing directory {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def statfs(self, path: str) -> dict:
        """Get filesystem statistics"""
        return {
            'f_bsize': 4096,
            'f_frsize': 4096,
            'f_blocks': 1000000,
            'f_bfree': 1000000,
            'f_bavail': 1000000,
            'f_files': 1000000,
            'f_ffree': 1000000,
            'f_favail': 1000000,
            'f_flag': 0,
            'f_namemax': 255,
        }
    
    def symlink(self, target: str, name: str) -> int:
        """Create a symbolic link"""
        raise FuseOSError(os.ENOSYS)
    
    def truncate(self, path: str, length: int, fh=None) -> int:
        """Truncate a file"""
        # Truncation is handled by writing empty bytes
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        try:
            # Read current file
            current_data = contract_manager.read_file(rel_path, 0, 0, account)
            if current_data is None:
                current_data = b''
            
            if length < len(current_data):
                # Truncate by writing only the first length bytes
                truncated_data = current_data[:length]
                success = contract_manager.write_file(rel_path, truncated_data, 0, account)
            else:
                # Extend with zeros
                new_data = current_data + b'\x00' * (length - len(current_data))
                success = contract_manager.write_file(rel_path, new_data, 0, account)
            
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error truncating file {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def unlink(self, path: str) -> int:
        """Remove a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        try:
            success = contract_manager.delete_entry(rel_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error removing file {path}: {e}")
            raise FuseOSError(os.EIO)
    
    def utimens(self, path: str, times=None) -> int:
        """Update file access and modification times"""
        # Timestamps are managed by the contract
        return 0
    
    def write(self, path: str, data: bytes, offset: int, fh) -> int:
        """Write to a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(os.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account)
        if contract_manager is None:
            raise FuseOSError(os.EIO)
        
        try:
            success = contract_manager.write_file(rel_path, data, offset, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return len(data)
            else:
                raise FuseOSError(os.EIO)
        except Exception as e:
            logger.error(f"Error writing to file {path}: {e}")
            raise FuseOSError(os.EIO)
