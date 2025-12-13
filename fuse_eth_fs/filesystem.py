"""
EthFS - Ethereum-backed FUSE filesystem

Virtual filesystem structure:
/<chain_id>/<account_address>/<files_and_directories>

Example:
/1337/0x1234.../file.txt
/1337/0x1234.../documents/
"""

import os
import errno
import stat
import time
from typing import Dict, Optional
from fuse import FUSE, FuseOSError, Operations, LoggingMixIn

from .rpc_manager import RPCManager
from .contract_manager import ContractManager


class EthFS(LoggingMixIn, Operations):
    """
    FUSE filesystem backed by Ethereum smart contracts
    
    Structure:
    - Root: Lists chain IDs as directories
    - Chain level: Lists account addresses as directories
    - Account level: User files and directories stored in smart contract
    """
    
    def __init__(self, contract_addresses: Dict[int, str]):
        """
        Initialize the filesystem
        
        Args:
            contract_addresses: Mapping of chain_id -> contract_address
        """
        self.rpc_manager = RPCManager()
        self.contract_managers: Dict[int, ContractManager] = {}
        
        # Initialize contract managers for each chain
        for chain_id in self.rpc_manager.get_all_chain_ids():
            if chain_id in contract_addresses:
                w3 = self.rpc_manager.get_connection(chain_id)
                self.contract_managers[chain_id] = ContractManager(
                    w3, contract_addresses[chain_id]
                )
        
        # Default account for writes (should be configurable)
        self.default_account = os.environ.get('ETH_ACCOUNT', '0x0000000000000000000000000000000000000000')
        
        # In-memory cache for directory structure
        self.dir_cache = {}
    
    def _parse_path(self, path: str) -> tuple:
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
    
    def _get_storage_slot_for_path(self, chain_id: int, account: str, rel_path: str) -> Optional[int]:
        """Get storage slot for a given path using ContractManager's mapping"""
        if chain_id not in self.contract_managers:
            return None
        contract_mgr = self.contract_managers[chain_id]
        # Use ContractManager's internal mapping to get storage slot
        key = (account.lower(), rel_path)
        if key in contract_mgr.path_to_slot:
            return contract_mgr.path_to_slot[key]
        return None
    
    def _find_entry_by_path(self, chain_id: int, account: str, rel_path: str) -> Optional[tuple]:
        """
        Find an entry by path using IFileSystem.getEntries() and getEntry()
        Returns: (storage_slot, entry_info) or None
        """
        if chain_id not in self.contract_managers:
            return None
        
        contract_mgr = self.contract_managers[chain_id]
        contract = contract_mgr.contract
        
        # First try to get storage slot from mapping
        storage_slot = self._get_storage_slot_for_path(chain_id, account, rel_path)
        if storage_slot is not None:
            try:
                entry = contract.functions.getEntry(storage_slot).call()
                entry_type, owner, name, body, timestamp, entry_exists, file_size, dir_target = entry
                if entry_exists and owner.lower() == account.lower():
                    # Verify the name matches (for files)
                    if entry_type == 0:  # FILE
                        filename = rel_path.split('/')[-1] if '/' in rel_path else rel_path
                        if name.decode('utf-8', errors='ignore') == filename:
                            return (storage_slot, entry)
                    else:  # DIRECTORY
                        # For directories, we need to check if the path matches
                        # This is a simplified check - in practice, directory structure
                        # might need more sophisticated matching
                        return (storage_slot, entry)
            except Exception:
                pass
        
        # If not found in mapping, search all entries
        try:
            all_slots = contract.functions.getEntries().call()
            account_lower = account.lower()
            filename = rel_path.split('/')[-1] if '/' in rel_path else rel_path
            
            for slot in all_slots:
                try:
                    entry = contract.functions.getEntry(slot).call()
                    entry_type, owner, name_bytes, body, timestamp, entry_exists, file_size, dir_target = entry
                    
                    if entry_exists and owner.lower() == account_lower:
                        # For files, check if name matches
                        if entry_type == 0:  # FILE
                            entry_name = name_bytes.decode('utf-8', errors='ignore')
                            if entry_name == filename:
                                # Update mapping for future lookups
                                key = (account.lower(), rel_path)
                                contract_mgr.path_to_slot[key] = slot
                                contract_mgr.slot_to_path[(account.lower(), slot)] = rel_path
                                return (slot, entry)
                        # For directories, we'd need more sophisticated matching
                        # For now, skip directories in this search
                except Exception:
                    continue
        except Exception:
            pass
        
        return None
    
    def getattr(self, path, fh=None):
        """Get file attributes"""

        print(f"Getting attributes for path: {path}")
        chain_id, account, rel_path = self._parse_path(path)
        print(f"Parsed path: {chain_id}, {account}, {rel_path}")
        # Root directory
        if chain_id is None:
            return dict(
                st_mode=(stat.S_IFDIR | 0o755),
                st_nlink=2,
                st_ctime=time.time(),
                st_mtime=time.time(),
                st_atime=time.time()
            )
        
        # Chain ID directory
        if account is None:
            if chain_id in self.rpc_manager.get_all_chain_ids():
                return dict(
                    st_mode=(stat.S_IFDIR | 0o755),
                    st_nlink=2,
                    st_ctime=time.time(),
                    st_mtime=time.time(),
                    st_atime=time.time()
                )
            raise FuseOSError(errno.ENOENT)
        
        # Account directory - always a directory that lists entries
        if rel_path is None:
            # The account level is always a directory that contains entries
            return dict(
                st_mode=(stat.S_IFDIR | 0o755),
                st_nlink=2,
                st_ctime=time.time(),
                st_mtime=time.time(),
                st_atime=time.time()
            )
        # File or directory in contract storage - use IFileSystem.getEntry()
        result = self._find_entry_by_path(chain_id, account, rel_path)
        print(f"Result: {result}")
        if result is None:
            raise FuseOSError(errno.ENOENT)
        
        storage_slot, entry = result
        entry_type, owner, name, body, timestamp, entry_exists, file_size, dir_target = entry
        
        print(f"Entry type: {entry_type}")
        print(f"Entry exists: {entry_exists}")
        if not entry_exists:
            raise FuseOSError(errno.ENOENT)
        
        print(f"Entry type: {entry_type}")
        if entry_type == 1:  # DIRECTORY
            return dict(
                st_mode=(stat.S_IFDIR | 0o755),
                st_nlink=2,
                st_ctime=timestamp,
                st_mtime=timestamp,
                st_atime=timestamp
            )
        else:  # FILE
            return dict(
                st_mode=(stat.S_IFREG | 0o644),
                st_nlink=1,
                st_size=file_size,
                st_ctime=timestamp,
                st_mtime=timestamp,
                st_atime=timestamp
            )
    
    def readdir(self, path, fh):
        """Read directory contents using IFileSystem.getEntries() and getEntry()"""
        chain_id, account, rel_path = self._parse_path(path)
        entries = ['.', '..']
        
        # Root directory - list chain IDs
        if chain_id is None:
            for cid in self.rpc_manager.get_all_chain_ids():
                entries.append(str(cid))
            return entries
        
        # Chain directory - list accounts (for demo, return default account)
        if account is None:
            # In a real implementation, you'd query the blockchain for accounts
            # For now, we'll show the default account
            entries.append(self.default_account)
            return entries
        
        # Account directory or subdirectory - use IFileSystem.getEntries()
        if chain_id not in self.contract_managers:
            return entries
        
        contract_mgr = self.contract_managers[chain_id]
        contract = contract_mgr.contract
        
        try:
            # Get all storage slots using IFileSystem.getEntries()
            print(f"Getting all storage slots for account: {account}", contract.address)
            print(contract.functions)
            print(contract.functions.getEntries)
            print(contract.functions.getEntries().call())
            all_slots = contract.functions.getEntries().call()
            account_lower = account.lower()
            
            # Determine the current directory prefix
            if rel_path is None:
                current_prefix = ""
            else:
                current_prefix = rel_path + "/"
            
            seen = set()
            
            # Iterate through all entries and filter by owner
            for slot in all_slots:
                try:
                    # Use IFileSystem.getEntry() to get entry information
                    entry = contract.functions.getEntry(slot).call()
                    entry_type, owner, name_bytes, body, timestamp, entry_exists, file_size, dir_target = entry
                    print(f"Entry: {entry}")
                    print(f"Entry type: {entry_type}")
                    print(f"Owner: {owner}")
                    print(f"Name: {name_bytes}")
                    print(f"Body: {body}")
                    print(f"Timestamp: {timestamp}")
                    print(f"Entry exists: {entry_exists}")
                    print(f"File size: {file_size}")
                    print(f"Directory target: {dir_target}")
                    if not entry_exists:
                        continue
                    
                    # Try to get path from mapping first
                    path_for_slot = contract_mgr._get_path_from_slot(account, slot)
                    print(f"Path for slot: {path_for_slot}")
                    if path_for_slot is None:
                        # No mapping exists - this happens for entries created outside our mapping
                        # For files, use the name directly
                        if entry_type == 0:  # FILE
                            entry_name = name_bytes.decode('utf-8', errors='ignore')
                            if entry_name and current_prefix == "":
                                # Root level - use entry name directly
                                if entry_name not in seen:
                                    seen.add(entry_name)
                                    entries.append(entry_name)
                                    # Update mapping for future lookups
                                    key = (account.lower(), entry_name)
                                    contract_mgr.path_to_slot[key] = slot
                                    contract_mgr.slot_to_path[(account.lower(), slot)] = entry_name
                        # For directories without mapping, use slot number as name
                        elif entry_type == 1:  # DIRECTORY
                            if current_prefix == "":
                                # Root level - use slot number as directory name
                                dir_name = f"dir_{slot}"
                                if dir_name not in seen:
                                    seen.add(dir_name)
                                    entries.append(dir_name)
                                    # Update mapping
                                    key = (account.lower(), dir_name)
                                    contract_mgr.path_to_slot[key] = slot
                                    contract_mgr.slot_to_path[(account.lower(), slot)] = dir_name
                        continue
                    
                    print(f"Path for slot: {path_for_slot}")
                    print(f"Current prefix: {current_prefix}")
                    # Check if this path is a direct child of current path
                    if current_prefix and not path_for_slot.startswith(current_prefix):
                        continue
                    
                    # Get the relative part
                    if current_prefix:
                        rel = path_for_slot[len(current_prefix):]
                    else:
                        rel = path_for_slot
                    
                    # Get only direct children (first component of path)
                    if '/' in rel:
                        # This is a deeper path, just get the directory name
                        child = rel.split('/')[0]
                    else:
                        child = rel
                    
                    if child and child not in seen:
                        seen.add(child)
                        entries.append(child)
                        
                except Exception as e:
                    # Log error but continue processing other entries
                    print(f"Error processing slot {slot}: {e}")
                    continue
                    
        except Exception as e:
            print(f"Error reading directory {path}: {e}")
            pass
        
        return entries
    
    def read(self, path, size, offset, fh):
        """Read file content using IFileSystem.readFile()"""
        chain_id, account, rel_path = self._parse_path(path)
        print(f"Reading file content for path: {path}")
        print(f"Parsed path: {chain_id}, {account}, {rel_path}")
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        # Find the entry to get storage slot
        result = self._find_entry_by_path(chain_id, account, rel_path)
        if result is None:
            raise FuseOSError(errno.ENOENT)
        
        storage_slot, entry = result
        entry_type, owner, name, body, timestamp, entry_exists, file_size, dir_target = entry
        
        if not entry_exists or entry_type != 0:  # Must be a file
            raise FuseOSError(errno.ENOENT)
        
        # Use IFileSystem.readFile() to read the file content
        contract_mgr = self.contract_managers[chain_id]
        contract = contract_mgr.contract
        
        try:
            print(f"Reading file content for path: {path}")
            print(f"Storage slot: {storage_slot}")
            print(f"Offset: {offset}")
            print(f"Length: {length}")
            print(f"File size: {file_size}")
            print(f"Contract: {contract.address}")
            print(contract.functions)
            print(contract.functions.readFile)
            # Read the requested portion using readFile
            # If size is 0 or very large, read the entire remaining file
            length = size if size > 0 else (file_size - offset)
            if offset + length > file_size:
                length = file_size - offset if offset < file_size else 0
            
            if length <= 0:
                return b''
            
            body = contract.functions.readFile(storage_slot, offset, length).call()
            return body
        except Exception as e:
            # Fallback to getting full entry if readFile fails
            body = entry[3]  # body is at index 3
            return body[offset:offset + size]
    
    def write(self, path, data, offset, fh):
        """
        Write to file
        
        Note: Partial writes (offset > 0) are inefficient as they require reading
        the entire file from the blockchain before writing. For production use,
        consider implementing a caching layer or documenting this limitation.
        """
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        
        # Store the original data length for return value
        bytes_to_write = len(data)
        
        # Handle partial writes by reading existing body and merging
        # WARNING: This is expensive as it reads the entire file from blockchain
        if offset != 0:
            entry = contract_mgr.get_entry(account, rel_path)
            if entry and entry[5]:  # entry[5] is 'entryExists'
                existing = bytearray(entry[3])  # body is at index 3
                # Extend the buffer if offset is beyond current length
                if offset + len(data) > len(existing):
                    existing.extend(b'\0' * (offset + len(data) - len(existing)))
                # Write data at the specified offset
                existing[offset:offset + len(data)] = data
                data = bytes(existing)
            else:
                # File doesn't exist, create with padding
                data = b'\0' * offset + data
        
        # Update the file
        if contract_mgr.exists(account, rel_path):
            contract_mgr.update_file(rel_path, data, account)
        else:
            contract_mgr.create_file(rel_path, data, account)
        
        # Return the number of bytes written (not the total file size)
        return bytes_to_write
    
    def create(self, path, mode):
        """Create a new file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        contract_mgr.create_file(rel_path, b'', account)
        
        return 0
    
    def mkdir(self, path, mode):
        """Create a directory"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        contract_mgr.create_directory(rel_path, account)
    
    def unlink(self, path):
        """Delete a file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        contract_mgr.delete_entry(rel_path, account)
    
    def rmdir(self, path):
        """Remove a directory"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        contract_mgr.delete_entry(rel_path, account)
    
    # Required FUSE operations
    def chmod(self, path, mode):
        """Change file mode - not supported, just return success"""
        return 0
    
    def chown(self, path, uid, gid):
        """Change file owner - not supported, just return success"""
        return 0
    
    def utimens(self, path, times=None):
        """Update file timestamps - not supported, just return success"""
        return 0
    
    def truncate(self, path, length, fh=None):
        """Truncate file to specified length"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        entry = contract_mgr.get_entry(account, rel_path)
        
        if entry and entry[5]:  # entry[5] is 'entryExists'
            body = entry[3]  # body is at index 3
            if length < len(body):
                new_body = body[:length]
            else:
                new_body = body + b'\0' * (length - len(body))
            
            contract_mgr.update_file(rel_path, new_body, account)
        
        return 0
