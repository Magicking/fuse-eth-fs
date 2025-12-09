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
    
    def getattr(self, path, fh=None):
        """Get file attributes"""
        chain_id, account, rel_path = self._parse_path(path)
        
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
        
        # Account directory
        if rel_path is None:
            return dict(
                st_mode=(stat.S_IFDIR | 0o755),
                st_nlink=2,
                st_ctime=time.time(),
                st_mtime=time.time(),
                st_atime=time.time()
            )
        
        # File or directory in contract storage
        if chain_id not in self.contract_managers:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        entry = contract_mgr.get_entry(account, rel_path)
        
        if entry is None or not entry[5]:  # entry[5] is 'exists'
            raise FuseOSError(errno.ENOENT)
        
        # entry = (name, entryType, owner, content, timestamp, exists)
        entry_type = entry[1]  # 0 = FILE, 1 = DIRECTORY
        content = entry[3]
        timestamp = entry[4]
        
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
                st_size=len(content),
                st_ctime=timestamp,
                st_mtime=timestamp,
                st_atime=timestamp
            )
    
    def readdir(self, path, fh):
        """Read directory contents"""
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
        
        # Account directory or subdirectory
        if chain_id not in self.contract_managers:
            return entries
        
        contract_mgr = self.contract_managers[chain_id]
        
        # Get all paths for the account
        all_paths = contract_mgr.get_account_paths(account)
        
        # Filter paths that are direct children of current path
        if rel_path is None:
            # Root of account directory
            current_prefix = ""
        else:
            current_prefix = rel_path + "/"
        
        seen = set()
        for full_path in all_paths:
            if current_prefix and not full_path.startswith(current_prefix):
                continue
            
            # Get the relative part
            if current_prefix:
                rel = full_path[len(current_prefix):]
            else:
                rel = full_path
            
            # Get only direct children
            if '/' in rel:
                # This is a deeper path, just get the directory name
                child = rel.split('/')[0]
            else:
                child = rel
            
            if child and child not in seen:
                seen.add(child)
                entries.append(child)
        
        return entries
    
    def read(self, path, size, offset, fh):
        """Read file content"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        entry = contract_mgr.get_entry(account, rel_path)
        
        if entry is None or not entry[5]:
            raise FuseOSError(errno.ENOENT)
        
        content = entry[3]
        return content[offset:offset + size]
    
    def write(self, path, data, offset, fh):
        """Write to file"""
        chain_id, account, rel_path = self._parse_path(path)
        
        if chain_id not in self.contract_managers or rel_path is None:
            raise FuseOSError(errno.ENOENT)
        
        contract_mgr = self.contract_managers[chain_id]
        
        # For simplicity, we don't support partial writes (offset must be 0)
        # In a production system, you'd need to handle this properly
        if offset != 0:
            # Read existing content and merge
            entry = contract_mgr.get_entry(account, rel_path)
            if entry and entry[5]:
                existing = bytearray(entry[3])
                existing[offset:offset + len(data)] = data
                data = bytes(existing)
        
        # Update the file
        if contract_mgr.exists(account, rel_path):
            contract_mgr.update_file(rel_path, data, account)
        else:
            contract_mgr.create_file(rel_path, data, account)
        
        return len(data)
    
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
        
        if entry and entry[5]:
            content = entry[3]
            if length < len(content):
                new_content = content[:length]
            else:
                new_content = content + b'\0' * (length - len(content))
            
            contract_mgr.update_file(rel_path, new_content, account)
        
        return 0
