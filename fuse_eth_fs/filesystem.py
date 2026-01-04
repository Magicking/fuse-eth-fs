"""
FUSE filesystem implementation for Ethereum-backed filesystem
"""
import os
import errno
import logging
import stat
import time
from typing import Dict, Optional, Tuple, List, Set
from fuse import FuseOSError, Operations, LoggingMixIn
from web3 import Web3
from eth_account import Account

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
        
        # Load private key from environment and create account
        private_key = os.environ.get('PRIVATE_KEY')
        self.transaction_account = None
        if private_key:
            try:
                # Remove '0x' prefix if present
                if private_key.startswith('0x'):
                    private_key = private_key[2:]
                self.transaction_account = Account.from_key(private_key)
                logger.info(f"Loaded transaction account: {self.transaction_account.address}")
            except Exception as e:
                logger.warning(f"Failed to load account from PRIVATE_KEY: {e}")
                logger.warning("Transactions will fail if PRIVATE_KEY is not set correctly")
        
        # Initialize contract managers for each chain
        self.contract_managers: Dict[int, ContractManager] = {}
        for chain_id, address in contract_addresses.items():
            w3 = self.rpc_manager.get_connection(chain_id)
            if w3 is None:
                logger.warning(f"Could not connect to chain {chain_id}, skipping")
                continue
            self.contract_managers[chain_id] = ContractManager(w3, address, transaction_account=self.transaction_account)
        
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
                        # Store slot for all accounts (world-readable)
                        # We still track by owner for organizational purposes, but don't filter by it
                        if (chain_id, owner_lower) not in self.slot_cache:
                            self.slot_cache[(chain_id, owner_lower)] = set()
                        self.slot_cache[(chain_id, owner_lower)].add(slot)
                        
                        # Build path from entry name (which stores the full path)
                        # Both files and directories now store their names
                        if name_bytes:
                            try:
                                full_path = name_bytes.decode('utf-8')
                                # Store entry info with full path for the owner
                                # Also store it for any account that might access it (world-readable)
                                # For now, we'll store it under the owner's key but allow access from any account
                                self.entry_cache[(chain_id, owner_lower, full_path)] = {
                                    'slot': slot,
                                    'type': entry_type,
                                    'owner': owner,
                                    'size': file_size,
                                    'timestamp': timestamp,
                                    'name': full_path.split('/')[-1] if '/' in full_path else full_path,
                                    'directory_target': dir_target if dir_target and dir_target != '0x0000000000000000000000000000000000000000' else None
                                }
                            except UnicodeDecodeError:
                                logger.warning(f"Could not decode name for slot {slot}")
                    except Exception as e:
                        logger.debug(f"Error processing slot {slot} on chain {chain_id}: {e}")
            except Exception as e:
                logger.error(f"Error refreshing cache for chain {chain_id}: {e}")
    
    def _get_entry_info(self, chain_id: int, account: str, path: str) -> Optional[dict]:
        """Get entry information from cache or contract (world-readable)"""
        account_lower = account.lower()
        
        # Check cache first - try account-specific cache, then check all entries
        if (chain_id, account_lower, path) in self.entry_cache:
            return self.entry_cache[(chain_id, account_lower, path)]
        
        # World-readable: check all entries in cache regardless of owner
        for (c_id, acc, file_path), entry_info in self.entry_cache.items():
            if c_id == chain_id and file_path == path:
                return entry_info
        
        # Try to get from contract (world-readable, check all entries)
        if chain_id not in self.contract_managers:
            return None
        
        # First, try to resolve which contract to use for this path
        contract_manager = self._get_contract_manager(chain_id, account, path)
        if contract_manager is None:
            return None
        
        # Check if it's a directory by checking if any files start with this path
        # This is a fallback for directories that might not be in cache yet
        # Check all entries regardless of owner (world-readable)
        if path and not path.endswith('/'):
            # Check if this is a directory
            dir_path = path + '/'
            for (c_id, acc, file_path) in self.entry_cache.keys():
                if c_id == chain_id and file_path.startswith(dir_path):
                    return {
                        'type': ENTRY_TYPE_DIRECTORY,
                        'owner': account,
                        'size': 0,
                        'timestamp': int(time.time()),
                        'name': path.split('/')[-1] if '/' in path else path
                    }
        
        # Try to get entry from contract (world-readable)
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, path)
        
        try:
            entry = contract_manager.get_entry(account, relative_path, any_owner=True)
            if entry:
                entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                if exists:
                    # Find the slot (any owner)
                    slot = contract_manager._find_slot_by_path(account, relative_path, any_owner=True)
                    info = {
                        'slot': slot,
                        'type': entry_type,
                        'owner': owner,
                        'size': file_size,
                        'timestamp': timestamp,
                        'name': path.split('/')[-1] if '/' in path else path,
                        'directory_target': dir_target if dir_target and dir_target != '0x0000000000000000000000000000000000000000' else None
                    }
                    # Cache it with the original path (not relative path)
                    # Cache under the actual owner, but allow access from any account
                    owner_lower = owner.lower()
                    self.entry_cache[(chain_id, owner_lower, path)] = info
                    return info
        except Exception as e:
            logger.debug(f"Error getting entry for {path}: {e}")
        
        return None
    
    def _resolve_contract_address(self, chain_id: int, account: str, path: str) -> Optional[str]:
        """
        Resolve the contract address to use for a given path.
        For directories: checks if the directory itself has a directoryTarget.
        For files: walks up the directory tree to find if any parent directory has a directoryTarget.
        Returns the directoryTarget address if found, otherwise returns the default contract address.
        
        NOTE: This method uses the default contract manager directly to avoid circular dependencies.
        """
        if chain_id not in self.contract_addresses:
            return None
        
        # Start with the default contract address
        default_address = self.contract_addresses[chain_id]
        
        # If path is empty, use default
        if not path:
            return default_address
        
        if chain_id not in self.contract_managers:
            return default_address
        
        account_lower = account.lower()
        default_contract_manager = self.contract_managers[chain_id]
        
        # First, check if the path itself is a directory with a directoryTarget
        # This handles the case where we're listing a directory
        cache_key = (chain_id, account_lower, path)
        if cache_key in self.entry_cache:
            entry_info = self.entry_cache[cache_key]
            if entry_info and entry_info.get('type') == ENTRY_TYPE_DIRECTORY:
                dir_target = entry_info.get('directory_target')
                if dir_target:
                    return dir_target
        else:
            # Try to get from default contract directly (avoiding circular dependency)
            try:
                entry = default_contract_manager.get_entry(account, path)
                if entry:
                    entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                    if exists and entry_type == ENTRY_TYPE_DIRECTORY:
                        if dir_target and dir_target != '0x0000000000000000000000000000000000000000':
                            return dir_target
            except Exception:
                pass
        
        # If not a directory with target, walk up the directory tree to find parent with directoryTarget
        path_parts = path.split('/')
        # Check from the immediate parent up to the root
        for i in range(len(path_parts) - 1, 0, -1):
            parent_path = '/'.join(path_parts[:i])
            cache_key = (chain_id, account_lower, parent_path)
            
            if cache_key in self.entry_cache:
                entry_info = self.entry_cache[cache_key]
                if entry_info and entry_info.get('type') == ENTRY_TYPE_DIRECTORY:
                    dir_target = entry_info.get('directory_target')
                    if dir_target:
                        return dir_target
            else:
                # Try to get from default contract directly (avoiding circular dependency)
                try:
                    entry = default_contract_manager.get_entry(account, parent_path)
                    if entry:
                        entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                        if exists and entry_type == ENTRY_TYPE_DIRECTORY:
                            if dir_target and dir_target != '0x0000000000000000000000000000000000000000':
                                return dir_target
                except Exception:
                    pass
        
        return default_address
    
    def _get_parent_directory_with_target(self, chain_id: int, account: str, path: str) -> Optional[Tuple[str, str]]:
        """
        Find the parent directory that has a directoryTarget for a given path.
        Returns (parent_path, directory_target_address) if found, None otherwise.
        
        NOTE: This method uses the default contract manager directly to avoid circular dependencies.
        """
        if not path:
            return None
        
        if chain_id not in self.contract_managers:
            return None
        
        account_lower = account.lower()
        path_parts = path.split('/')
        default_contract_manager = self.contract_managers[chain_id]
        
        # Walk up the directory tree to find parent with directoryTarget
        for i in range(len(path_parts), 0, -1):
            parent_path = '/'.join(path_parts[:i])
            cache_key = (chain_id, account_lower, parent_path)
            
            if cache_key in self.entry_cache:
                entry_info = self.entry_cache[cache_key]
                if entry_info and entry_info.get('type') == ENTRY_TYPE_DIRECTORY:
                    dir_target = entry_info.get('directory_target')
                    if dir_target:
                        return (parent_path, dir_target)
            else:
                # Try to get from default contract directly (avoiding circular dependency)
                try:
                    entry = default_contract_manager.get_entry(account, parent_path)
                    if entry:
                        entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                        if exists and entry_type == ENTRY_TYPE_DIRECTORY:
                            if dir_target and dir_target != '0x0000000000000000000000000000000000000000':
                                return (parent_path, dir_target)
                except Exception:
                    pass
        
        return None
    
    def _get_relative_path_in_subdirectory(self, chain_id: int, account: str, path: str) -> str:
        """
        Get the relative path within a subdirectory contract.
        If the path is within a directory that has a directoryTarget, returns the path relative to that directory.
        Otherwise, returns the original path.
        """
        parent_info = self._get_parent_directory_with_target(chain_id, account, path)
        if parent_info is None:
            return path
        
        parent_path, _ = parent_info
        if path.startswith(parent_path + '/'):
            # Return the path relative to the parent directory
            return path[len(parent_path + '/'):]
        elif path == parent_path:
            # The path itself is the directory with target
            return ''
        else:
            return path
    
    def _get_contract_manager(self, chain_id: int, account: str, path: str = None) -> Optional[ContractManager]:
        """
        Get contract manager for the given path.
        If path is a subdirectory within a directory that has a directoryTarget,
        returns the contract manager for that target address.
        """
        if chain_id not in self.contract_managers:
            return None
        
        # If no path specified, use default contract
        if path is None:
            return self.contract_managers[chain_id]
        
        # Resolve the contract address for this path
        contract_address = self._resolve_contract_address(chain_id, account, path)
        if contract_address is None:
            return self.contract_managers[chain_id]
        
        # If it's the default contract, return the existing manager
        default_address = self.contract_addresses.get(chain_id)
        if contract_address.lower() == default_address.lower():
            return self.contract_managers[chain_id]
        
        # Otherwise, we need to create/get a contract manager for this address
        # Check if we already have one cached
        cache_key = (chain_id, contract_address.lower())
        if not hasattr(self, '_contract_manager_cache'):
            self._contract_manager_cache: Dict[Tuple[int, str], ContractManager] = {}
        
        if cache_key in self._contract_manager_cache:
            return self._contract_manager_cache[cache_key]
        
        # Create a new contract manager for this address
        w3 = self.rpc_manager.get_connection(chain_id)
        if w3 is None:
            return self.contract_managers[chain_id]  # Fallback to default
        
        try:
            new_manager = ContractManager(w3, contract_address, transaction_account=self.transaction_account)
            self._contract_manager_cache[cache_key] = new_manager
            return new_manager
        except Exception as e:
            logger.warning(f"Could not create contract manager for {contract_address}: {e}")
            return self.contract_managers[chain_id]  # Fallback to default
    
    def _list_directory(self, chain_id: int, account: str, path: str) -> List[str]:
        """List directory contents"""
        entries = set()
        
        # Check if the path itself is a directory with a directoryTarget
        entry_info = self._get_entry_info(chain_id, account, path)
        if entry_info and entry_info.get('type') == ENTRY_TYPE_DIRECTORY:
            dir_target = entry_info.get('directory_target')
            if dir_target:
                # This directory has a directoryTarget, list entries from that contract
                contract_manager = self._get_contract_manager(chain_id, account, path)
                if contract_manager is None:
                    return []
                
                try:
                    slots = contract_manager.contract.functions.getEntries().call()
                    for slot in slots:
                        try:
                            entry = contract_manager.contract.functions.getEntry(slot).call()
                            entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                            
                            # World-readable: show all entries regardless of owner
                            if exists:
                                if name_bytes:
                                    try:
                                        entry_name = name_bytes.decode('utf-8')
                                        # In subdirectory contracts, entries are stored with relative paths
                                        # When listing the root of a subdirectory contract, show all top-level entries
                                        if '/' in entry_name:
                                            # Entry is in a subdirectory, get the first component
                                            first_part = entry_name.split('/')[0]
                                            entries.add(first_part)
                                        else:
                                            # Entry is at root level
                                            entries.add(entry_name)
                                    except UnicodeDecodeError:
                                        pass
                        except Exception:
                            continue
                    return sorted(list(entries))
                except Exception as e:
                    logger.debug(f"Error listing directory from subdirectory contract: {e}")
                    return []
        
        # Get the contract manager for this path (may be different if parent has directoryTarget)
        contract_manager = self._get_contract_manager(chain_id, account, path)
        if contract_manager is None:
            return []
        
        # Get the contract address being used
        contract_address = self._resolve_contract_address(chain_id, account, path)
        if contract_address is None:
            return []
        
        # If we're using a different contract, we need to query that contract
        default_address = self.contract_addresses.get(chain_id)
        if contract_address.lower() != default_address.lower():
            # We're using a subdirectory contract, query it directly
            # Get relative path within the subdirectory contract
            relative_path = self._get_relative_path_in_subdirectory(chain_id, account, path)
            
            try:
                slots = contract_manager.contract.functions.getEntries().call()
                for slot in slots:
                    try:
                        entry = contract_manager.contract.functions.getEntry(slot).call()
                        entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                        
                        # World-readable: show all entries regardless of owner
                        if exists:
                            if name_bytes:
                                try:
                                    entry_name = name_bytes.decode('utf-8')
                                    # In subdirectory contracts, entries are stored with relative paths
                                    # If relative_path is empty (listing root of subdirectory contract), show all top-level entries
                                    if not relative_path:
                                        # Get the first component of the path
                                        if '/' in entry_name:
                                            first_part = entry_name.split('/')[0]
                                            entries.add(first_part)
                                        else:
                                            entries.add(entry_name)
                                    else:
                                        # We're listing a subdirectory within the subdirectory contract
                                        # Check if entry is in this subdirectory
                                        if entry_name.startswith(relative_path + '/'):
                                            remaining = entry_name[len(relative_path + '/'):]
                                            if remaining:
                                                next_part = remaining.split('/')[0]
                                                entries.add(next_part)
                                        elif entry_name == relative_path:
                                            # This is the directory itself, skip it
                                            pass
                                except UnicodeDecodeError:
                                    pass
                    except Exception:
                        continue
                return sorted(list(entries))
            except Exception as e:
                logger.debug(f"Error listing directory from subdirectory contract: {e}")
                return []
        
        # If path is empty, list all top-level files/directories (world-readable)
        if not path:
            for (c_id, acc, file_path), entry_info in self.entry_cache.items():
                if c_id == chain_id:
                    # Get the first component of the path
                    if '/' in file_path:
                        first_part = file_path.split('/')[0]
                        entries.add(first_part)
                    else:
                        entries.add(file_path)
        else:
            # List files and directories in this directory (world-readable, all owners)
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
            raise FuseOSError(errno.ENOENT)
        
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
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        # Create empty file
        try:
            success = contract_manager.create_file(relative_path, b'', account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error creating file {path}: {e}")
            raise FuseOSError(errno.EIO)
    
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
            # World-readable: check all entries regardless of owner
            dir_path = rel_path + '/' if rel_path else ''
            is_directory = False
            for (c_id, acc, file_path) in self.entry_cache.keys():
                if c_id == chain_id:
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
            raise FuseOSError(errno.ENOENT)
        
        # Determine file type
        if entry_info['type'] == ENTRY_TYPE_DIRECTORY:
            st_mode = stat.S_IFDIR | 0o755
            # For directories with directoryTarget, use the directory's own attributes
            # (the attributes from the parent directory entry that has the directoryTarget)
            return {
                'st_mode': st_mode,
                'st_nlink': 2,
                'st_size': 0,
                'st_ctime': entry_info.get('timestamp', time.time()),
                'st_mtime': entry_info.get('timestamp', time.time()),
                'st_atime': time.time(),
                'st_uid': self.default_uid,
                'st_gid': self.default_gid,
            }
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
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        try:
            # Create directory (using address(0) for organizational directories)
            success = contract_manager.create_directory(relative_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error creating directory {path}: {e}")
            raise FuseOSError(errno.EIO)
    
    def open(self, path: str, flags: int) -> int:
        """Open a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        entry_info = self._get_entry_info(chain_id, account, rel_path)
        if entry_info is None:
            raise FuseOSError(errno.ENOENT)
        
        if entry_info['type'] != ENTRY_TYPE_FILE:
            raise FuseOSError(errno.EISDIR)
        
        # Return a file handle (we don't need to track it, just return 0)
        return 0
    
    def read(self, path: str, size: int, offset: int, fh) -> bytes:
        """Read from a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        try:
            data = contract_manager.read_file(relative_path, offset, size, account)
            if data is None:
                return b''
            return data
        except Exception as e:
            logger.error(f"Error reading file {path}: {e}")
            raise FuseOSError(errno.EIO)
    
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
        raise FuseOSError(errno.EINVAL)
    
    def rename(self, old: str, new: str) -> int:
        """Rename a file or directory"""
        # Not supported - would require updating the contract
        raise FuseOSError(errno.ENOSYS)
    
    def rmdir(self, path: str) -> int:
        """Remove a directory"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Check if directory is empty
        entries = self._list_directory(chain_id, account, rel_path)
        if entries:
            raise FuseOSError(errno.ENOTEMPTY)
        
        # For directories, we delete the directory entry itself (not using relative path)
        # because the directory entry is in the parent contract
        try:
            success = contract_manager.delete_entry(rel_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error removing directory {path}: {e}")
            raise FuseOSError(errno.EIO)
    
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
        raise FuseOSError(errno.ENOSYS)
    
    def truncate(self, path: str, length: int, fh=None) -> int:
        """Truncate a file"""
        # Truncation is handled by writing empty bytes
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        try:
            # Read current file
            current_data = contract_manager.read_file(relative_path, 0, 0, account)
            if current_data is None:
                current_data = b''
            
            if length < len(current_data):
                # Truncate by writing only the first length bytes
                truncated_data = current_data[:length]
                success = contract_manager.write_file(relative_path, truncated_data, 0, account)
            else:
                # Extend with zeros
                new_data = current_data + b'\x00' * (length - len(current_data))
                success = contract_manager.write_file(relative_path, new_data, 0, account)
            
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error truncating file {path}: {e}")
            raise FuseOSError(errno.EIO)
    
    def unlink(self, path: str) -> int:
        """Remove a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        try:
            success = contract_manager.delete_entry(relative_path, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return 0
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error removing file {path}: {e}")
            raise FuseOSError(errno.EIO)
    
    def utimens(self, path: str, times=None) -> int:
        """Update file access and modification times"""
        # Timestamps are managed by the contract
        return 0
    
    def write(self, path: str, data: bytes, offset: int, fh) -> int:
        """Write to a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id is None or account is None or rel_path is None:
            raise FuseOSError(errno.EINVAL)
        
        contract_manager = self._get_contract_manager(chain_id, account, rel_path)
        if contract_manager is None:
            raise FuseOSError(errno.EIO)
        
        # Get relative path within subdirectory contract if needed
        relative_path = self._get_relative_path_in_subdirectory(chain_id, account, rel_path)
        
        try:
            success = contract_manager.write_file(relative_path, data, offset, account)
            if success:
                # Refresh cache
                self._refresh_cache()
                return len(data)
            else:
                raise FuseOSError(errno.EIO)
        except Exception as e:
            logger.error(f"Error writing to file {path}: {e}")
            raise FuseOSError(errno.EIO)
