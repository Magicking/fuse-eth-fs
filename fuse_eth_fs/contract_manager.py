"""
Contract Manager for interacting with the FileSystem smart contract
"""
import json
import logging
from typing import Optional, List, Tuple, Dict
from web3 import Web3
from web3.contract import Contract

logger = logging.getLogger(__name__)


class ContractManager:
    """Manages interactions with the FileSystem smart contract"""
    
    def __init__(self, w3: Web3, contract_address: str, abi_path: Optional[str] = None):
        """
        Initialize the contract manager
        
        Args:
            w3: Web3 instance
            contract_address: Address of the deployed FileSystem contract
            abi_path: Path to the contract ABI JSON file (optional)
        """
        self.w3 = w3
        self.contract_address = Web3.to_checksum_address(contract_address)
        
        # Path to storage slot mapping per account (starting from 0)
        # Maps (account, path) -> storage_slot
        self.path_to_slot: Dict[tuple, int] = {}
        # Reverse mapping: storage_slot -> path (for account)
        self.slot_to_path: Dict[tuple, str] = {}
        # Track next available slot per account
        self.next_slot: Dict[str, int] = {}
        
        # Load ABI
        if abi_path:
            with open(abi_path, 'r') as f:
                abi = json.load(f)
        else:
            # ABI matching IFileSystem.sol interface
            abi = [
                {
                    "inputs": [
                        {"name": "name", "type": "bytes"},
                        {"name": "body", "type": "bytes"},
                        {"name": "offset", "type": "uint256"}
                    ],
                    "name": "createFile",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [
                        {"name": "target", "type": "address"}
                    ],
                    "name": "createDirectory",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [
                        {"name": "storageSlot", "type": "uint256"},
                        {"name": "body", "type": "bytes"},
                        {"name": "offset", "type": "uint256"}
                    ],
                    "name": "updateFile",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "storageSlot", "type": "uint256"}],
                    "name": "deleteEntry",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "storageSlot", "type": "uint256"}],
                    "name": "getEntry",
                    "outputs": [
                        {"name": "entryType", "type": "uint8"},
                        {"name": "owner", "type": "address"},
                        {"name": "name", "type": "bytes"},
                        {"name": "body", "type": "bytes"},
                        {"name": "timestamp", "type": "uint256"},
                        {"name": "entryExists", "type": "bool"},
                        {"name": "fileSize", "type": "uint256"},
                        {"name": "directoryTarget", "type": "address"}
                    ],
                    "stateMutability": "view",
                    "type": "function"
                },
                {
                    "inputs": [],
                    "name": "getEntries",
                    "outputs": [{"name": "", "type": "uint256[]"}],
                    "stateMutability": "view",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "storageSlot", "type": "uint256"}],
                    "name": "exists",
                    "outputs": [{"name": "", "type": "bool"}],
                    "stateMutability": "view",
                    "type": "function"
                },
                {
                    "inputs": [
                        {"name": "storageSlot", "type": "uint256"},
                        {"name": "offset", "type": "uint256"},
                        {"name": "length", "type": "uint256"}
                    ],
                    "name": "readFile",
                    "outputs": [{"name": "body", "type": "bytes"}],
                    "stateMutability": "view",
                    "type": "function"
                }
            ]
        
        self.contract: Contract = self.w3.eth.contract(
            address=self.contract_address,
            abi=abi
        )
    
    def _get_storage_slot(self, account: str, path: str) -> int:
        """
        Get or allocate a storage slot for a path.
        Storage slots start at 0 for each account.
        """
        key = (account.lower(), path)
        
        if key in self.path_to_slot:
            return self.path_to_slot[key]
        
        # Allocate new slot starting from 0
        if account.lower() not in self.next_slot:
            self.next_slot[account.lower()] = 0
        
        slot = self.next_slot[account.lower()]
        self.path_to_slot[key] = slot
        self.slot_to_path[(account.lower(), slot)] = path
        self.next_slot[account.lower()] = slot + 1
        
        return slot
    
    def _get_path_from_slot(self, account: str, slot: int) -> Optional[str]:
        """Get path from storage slot"""
        return self.slot_to_path.get((account.lower(), slot))
    
    def create_file(self, path: str, body: bytes, account: str) -> bool:
        """Create a file in the contract storage (storage slot auto-assigned)"""
        try:
            # Get existing slots before creation
            existing_slots = set(self.contract.functions.getEntries().call())
            
            # Extract filename from path
            filename = path.split('/')[-1] if '/' in path else path
            name_bytes = filename.encode('utf-8')
            
            # Create the file (contract will auto-assign storage slot)
            tx_hash = self.contract.functions.createFile(name_bytes, body, 0).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            
            # Find the newly assigned slot
            new_slots = set(self.contract.functions.getEntries().call())
            new_slot = (new_slots - existing_slots).pop() if (new_slots - existing_slots) else None
            
            if new_slot is not None:
                # Update our mapping
                key = (account.lower(), path)
                self.path_to_slot[key] = new_slot
                self.slot_to_path[(account.lower(), new_slot)] = path
                logger.info(f"Created file '{path}' at slot {new_slot} for account {account}")
            else:
                logger.warning(f"Created file '{path}' but could not determine assigned slot")
            
            return True
        except Exception as e:
            logger.error(f"Error creating file '{path}' for account {account}: {e}")
            return False
    
    def create_directory(self, path: str, account: str) -> bool:
        """Create a directory in the contract storage (storage slot auto-assigned)"""
        try:
            # Get existing slots before creation
            existing_slots = set(self.contract.functions.getEntries().call())
            
            # Directories point to address(0) by default (can be changed later)
            tx_hash = self.contract.functions.createDirectory("0x0000000000000000000000000000000000000000").transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            
            # Find the newly assigned slot
            new_slots = set(self.contract.functions.getEntries().call())
            new_slot = (new_slots - existing_slots).pop() if (new_slots - existing_slots) else None
            
            if new_slot is not None:
                # Update our mapping
                key = (account.lower(), path)
                self.path_to_slot[key] = new_slot
                self.slot_to_path[(account.lower(), new_slot)] = path
                logger.info(f"Created directory '{path}' at slot {new_slot} for account {account}")
            else:
                logger.warning(f"Created directory '{path}' but could not determine assigned slot")
            
            return True
        except Exception as e:
            logger.error(f"Error creating directory '{path}' for account {account}: {e}")
            return False
    
    def update_file(self, path: str, body: bytes, account: str) -> bool:
        """Update file body"""
        try:
            storage_slot = self._get_storage_slot(account, path)
            tx_hash = self.contract.functions.updateFile(storage_slot, body, 0).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            logger.info(f"Updated file '{path}' at slot {storage_slot} for account {account}")
            return True
        except Exception as e:
            logger.error(f"Error updating file '{path}' for account {account}: {e}")
            return False
    
    def delete_entry(self, path: str, account: str) -> bool:
        """Delete an entry (file or directory)"""
        try:
            storage_slot = self._get_storage_slot(account, path)
            tx_hash = self.contract.functions.deleteEntry(storage_slot).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            logger.info(f"Deleted entry '{path}' at slot {storage_slot} for account {account}")
            return True
        except Exception as e:
            logger.error(f"Error deleting entry '{path}' for account {account}: {e}")
            return False
    
    def get_entry(self, account: str, path: str) -> Optional[Tuple]:
        """
        Get entry information
        Returns: (entryType, owner, name, body, timestamp, entryExists, fileSize, directoryTarget)
        """
        try:
            storage_slot = self._get_storage_slot(account, path)
            result = self.contract.functions.getEntry(storage_slot).call()
            # Convert to tuple format expected by filesystem.py
            # entryType, owner, name, body, timestamp, entryExists, fileSize, directoryTarget
            return result
        except Exception as e:
            logger.debug(f"Error getting entry '{path}' for account {account}: {e}")
            return None
    
    def get_account_paths(self, account: str) -> List[str]:
        """
        Get all paths for an account by querying all storage slots
        and mapping them back to paths. Only returns paths we have mappings for.
        """
        try:
            # Get all storage slots that have entries
            slots = self.contract.functions.getEntries().call()
            
            paths = []
            account_lower = account.lower()
            for slot in slots:
                # Check if this slot belongs to this account
                try:
                    entry = self.contract.functions.getEntry(slot).call()
                    entry_type, owner, name, body, timestamp, exists, file_size, dir_target = entry
                    if exists and owner.lower() == account_lower:
                        # Try to find path for this slot
                        path = self._get_path_from_slot(account, slot)
                        if path:
                            paths.append(path)
                        # If we don't have a mapping, we skip it (can't determine the path)
                except:
                    pass
            
            return paths
        except Exception as e:
            logger.error(f"Error getting account paths for {account}: {e}")
            return []
    
    def exists(self, account: str, path: str) -> bool:
        """Check if an entry exists"""
        try:
            storage_slot = self._get_storage_slot(account, path)
            return self.contract.functions.exists(storage_slot).call()
        except Exception as e:
            logger.debug(f"Error checking existence of '{path}' for account {account}: {e}")
            return False
