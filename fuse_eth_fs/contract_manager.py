"""
Contract Manager for interacting with the FileSystem smart contract
"""
import json
import logging
from typing import Optional, List, Tuple, Dict
from web3 import Web3
from web3.contract import Contract
from eth_account import Account

logger = logging.getLogger(__name__)


class ContractManager:
    """Manages interactions with the FileSystem smart contract"""
    
    def __init__(self, w3: Web3, contract_address: str, abi_path: Optional[str] = None, transaction_account: Optional[Account] = None):
        """
        Initialize the contract manager
        
        Args:
            w3: Web3 instance
            contract_address: Address of the deployed FileSystem contract
            abi_path: Path to the contract ABI JSON file (optional)
            transaction_account: Account to use for signing transactions (optional)
        """
        self.w3 = w3
        self.contract_address = Web3.to_checksum_address(contract_address)
        self.transaction_account = transaction_account
        
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
                        {"name": "name", "type": "bytes"},
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
                },
                {
                    "inputs": [
                        {"name": "storageSlot", "type": "uint256"},
                        {"name": "offset", "type": "uint256"},
                        {"name": "body", "type": "bytes"}
                    ],
                    "name": "writeFile",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                }
            ]
        
        self.contract: Contract = self.w3.eth.contract(
            address=self.contract_address,
            abi=abi
        )
    
    def _send_transaction(self, function_call, tx_params: dict) -> str:
        """
        Send a transaction, signing it with the transaction_account if available.
        
        Args:
            function_call: The contract function call (e.g., contract.functions.createFile(...))
            tx_params: Transaction parameters (e.g., {'from': account})
            
        Returns:
            Transaction hash
        """
        if self.transaction_account:
            # Use transaction account address for the transaction
            tx_params_with_account = tx_params.copy()
            tx_params_with_account['from'] = self.transaction_account.address
            
            # Build the transaction
            tx = function_call.build_transaction(tx_params_with_account)
            
            # Ensure nonce is set (build_transaction might not set it)
            if 'nonce' not in tx:
                tx['nonce'] = self.w3.eth.get_transaction_count(self.transaction_account.address)
            
            # Ensure chain ID is set
            if 'chainId' not in tx:
                tx['chainId'] = self.w3.eth.chain_id
            
            # Get gas price if not set (for legacy transactions)
            if 'gasPrice' not in tx and 'maxFeePerGas' not in tx:
                tx['gasPrice'] = self.w3.eth.gas_price
            
            # Estimate gas if not provided
            if 'gas' not in tx:
                try:
                    tx['gas'] = function_call.estimate_gas(tx_params_with_account)
                except Exception as e:
                    logger.warning(f"Could not estimate gas, using default: {e}")
                    tx['gas'] = 100000  # Fallback gas limit
            
            # Sign the transaction
            signed_tx = self.transaction_account.sign_transaction(tx)
            # Send the signed transaction
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            return tx_hash
        else:
            # Fall back to default behavior (requires node to handle signing)
            return function_call.transact(tx_params)
    
    def _get_storage_slot(self, account: str, path: str) -> int:
        """
        Get storage slot for a path.
        First checks local mapping, then queries contract if not found.
        """
        key = (account.lower(), path)
        
        if key in self.path_to_slot:
            return self.path_to_slot[key]
        
        # Try to find existing slot by querying contract
        slot = self._find_slot_by_path(account, path)
        if slot is not None:
            return slot
        
        # If not found, we'll need to create it (slot will be auto-assigned by contract)
        # For now, return a placeholder - the actual slot will be determined after creation
        # This is a limitation: we can't know the slot before creation
        # So we should use this method only for existing entries
        raise ValueError(f"Storage slot not found for path '{path}' - entry may not exist")
    
    def _get_path_from_slot(self, account: str, slot: int) -> Optional[str]:
        """Get path from storage slot"""
        return self.slot_to_path.get((account.lower(), slot))
    
    def _find_slot_by_path(self, account: str, path: str, any_owner: bool = False) -> Optional[int]:
        """
        Find storage slot for a path by querying all entries and matching by name
        This is used when we don't have a local mapping
        
        Args:
            account: Account to search for (ignored if any_owner=True)
            path: Path to find
            any_owner: If True, find the file regardless of owner (for read operations)
        """
        try:
            slots = self.contract.functions.getEntries().call()
            path_bytes = path.encode('utf-8')
            
            for slot in slots:
                try:
                    entry = self.contract.functions.getEntry(slot).call()
                    entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry
                    
                    if exists and (any_owner or owner.lower() == account.lower()):
                        if (entry_type == 0 or entry_type == 1) and name_bytes == path_bytes:  # FILE or DIRECTORY type
                            # Update our mapping
                            key = (account.lower(), path)
                            self.path_to_slot[key] = slot
                            self.slot_to_path[(account.lower(), slot)] = path
                            return slot
                except:
                    continue
            return None
        except Exception as e:
            logger.debug(f"Error finding slot for path '{path}': {e}")
            return None
    
    def create_file(self, path: str, body: bytes, account: str) -> bool:
        """Create a file in the contract storage (storage slot auto-assigned)"""
        try:
            # Get existing slots before creation
            existing_slots = set(self.contract.functions.getEntries().call())
            
            # Store full path as the name to preserve directory structure
            name_bytes = path.encode('utf-8')
            
            # Create the file (contract will auto-assign storage slot)
            # Use transaction_account address if available, otherwise use account from path
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.createFile(name_bytes, body, 0),
                {'from': from_address}
            )
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
    
    def create_directory(self, path: str, account: str, target_address: Optional[str] = None) -> bool:
        """
        Create a directory in the contract storage (storage slot auto-assigned).
        Directories now store their name in the contract.
        
        Args:
            path: The directory path/name
            account: The account creating the directory
            target_address: Optional target FileSystem contract address.
                          If None, uses address(0) for organizational directories.
        """
        try:
            # Get existing slots before creation
            existing_slots = set(self.contract.functions.getEntries().call())
            
            # Store full path as the name to preserve directory structure
            name_bytes = path.encode('utf-8')
            
            # Use address(0) if no target specified (for organizational directories)
            if target_address is None:
                target_address = "0x0000000000000000000000000000000000000000"
            
            # Use transaction_account address if available, otherwise use account from path
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.createDirectory(name_bytes, target_address),
                {'from': from_address}
            )
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
            storage_slot = self._find_slot_by_path(account, path)
            if storage_slot is None:
                logger.error(f"File '{path}' not found for account {account}")
                return False
            # Use transaction_account address if available, otherwise use account from path
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.updateFile(storage_slot, body, 0),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            logger.info(f"Updated file '{path}' at slot {storage_slot} for account {account}")
            return True
        except Exception as e:
            logger.error(f"Error updating file '{path}' for account {account}: {e}")
            return False
    
    def delete_entry(self, path: str, account: str) -> bool:
        """Delete an entry (file or directory)"""
        try:
            storage_slot = self._find_slot_by_path(account, path)
            if storage_slot is None:
                logger.error(f"Entry '{path}' not found for account {account}")
                return False
            # Use transaction_account address if available, otherwise use account from path
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.deleteEntry(storage_slot),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            # Remove from mapping
            key = (account.lower(), path)
            if key in self.path_to_slot:
                del self.path_to_slot[key]
            if (account.lower(), storage_slot) in self.slot_to_path:
                del self.slot_to_path[(account.lower(), storage_slot)]
            logger.info(f"Deleted entry '{path}' at slot {storage_slot} for account {account}")
            return True
        except Exception as e:
            logger.error(f"Error deleting entry '{path}' for account {account}: {e}")
            return False
    
    def get_entry(self, account: str, path: str, any_owner: bool = False) -> Optional[Tuple]:
        """
        Get entry information (world-readable if any_owner=True)
        Returns: (entryType, owner, name, body, timestamp, entryExists, fileSize, directoryTarget)
        """
        try:
            storage_slot = self._find_slot_by_path(account, path, any_owner=any_owner)
            if storage_slot is None:
                return None
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
            storage_slot = self._find_slot_by_path(account, path)
            if storage_slot is None:
                return False
            return self.contract.functions.exists(storage_slot).call()
        except Exception as e:
            logger.debug(f"Error checking existence of '{path}' for account {account}: {e}")
            return False
    
    def write_file(self, path: str, body: bytes, offset: int, account: str) -> bool:
        """Write file body at a specific offset (creates file if it doesn't exist)"""
        try:
            # Try to find existing slot
            storage_slot = self._find_slot_by_path(account, path)
            
            if storage_slot is None:
                # File doesn't exist, create it
                return self.create_file(path, body, account)
            
            # File exists, write to it
            # Use transaction_account address if available, otherwise use account from path
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.writeFile(storage_slot, offset, body),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            logger.info(f"Wrote to file '{path}' at offset {offset} for account {account}")
            return True
        except Exception as e:
            logger.error(f"Error writing to file '{path}' for account {account}: {e}")
            return False
    
    def read_file(self, path: str, offset: int, length: int, account: str) -> Optional[bytes]:
        """Read file body at a specific offset (world-readable, no owner check)"""
        try:
            storage_slot = self._find_slot_by_path(account, path, any_owner=True)
            if storage_slot is None:
                return None
            result = self.contract.functions.readFile(storage_slot, offset, length).call()
            return result
        except Exception as e:
            logger.error(f"Error reading file '{path}' for account {account}: {e}")
            return None
