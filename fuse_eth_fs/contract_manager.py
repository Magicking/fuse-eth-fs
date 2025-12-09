"""
Contract Manager for interacting with the FileSystem smart contract
"""
import json
from typing import Optional, List, Tuple
from web3 import Web3
from web3.contract import Contract


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
        
        # Load ABI
        if abi_path:
            with open(abi_path, 'r') as f:
                abi = json.load(f)
        else:
            # Simplified ABI - include only the functions we need
            abi = [
                {
                    "inputs": [{"name": "path", "type": "string"}, {"name": "content", "type": "bytes"}],
                    "name": "createFile",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "path", "type": "string"}],
                    "name": "createDirectory",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "path", "type": "string"}, {"name": "content", "type": "bytes"}],
                    "name": "updateFile",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "path", "type": "string"}],
                    "name": "deleteEntry",
                    "outputs": [],
                    "stateMutability": "nonpayable",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "account", "type": "address"}, {"name": "path", "type": "string"}],
                    "name": "getEntry",
                    "outputs": [
                        {"name": "name", "type": "string"},
                        {"name": "entryType", "type": "uint8"},
                        {"name": "owner", "type": "address"},
                        {"name": "content", "type": "bytes"},
                        {"name": "timestamp", "type": "uint256"},
                        {"name": "exists", "type": "bool"}
                    ],
                    "stateMutability": "view",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "account", "type": "address"}],
                    "name": "getAccountPaths",
                    "outputs": [{"name": "", "type": "string[]"}],
                    "stateMutability": "view",
                    "type": "function"
                },
                {
                    "inputs": [{"name": "account", "type": "address"}, {"name": "path", "type": "string"}],
                    "name": "exists",
                    "outputs": [{"name": "", "type": "bool"}],
                    "stateMutability": "view",
                    "type": "function"
                }
            ]
        
        self.contract: Contract = self.w3.eth.contract(
            address=self.contract_address,
            abi=abi
        )
    
    def create_file(self, path: str, content: bytes, account: str) -> bool:
        """Create a file in the contract storage"""
        try:
            tx_hash = self.contract.functions.createFile(path, content).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            return True
        except Exception as e:
            print(f"Error creating file: {e}")
            return False
    
    def create_directory(self, path: str, account: str) -> bool:
        """Create a directory in the contract storage"""
        try:
            tx_hash = self.contract.functions.createDirectory(path).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            return True
        except Exception as e:
            print(f"Error creating directory: {e}")
            return False
    
    def update_file(self, path: str, content: bytes, account: str) -> bool:
        """Update file content"""
        try:
            tx_hash = self.contract.functions.updateFile(path, content).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            return True
        except Exception as e:
            print(f"Error updating file: {e}")
            return False
    
    def delete_entry(self, path: str, account: str) -> bool:
        """Delete an entry (file or directory)"""
        try:
            tx_hash = self.contract.functions.deleteEntry(path).transact({'from': account})
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
            return True
        except Exception as e:
            print(f"Error deleting entry: {e}")
            return False
    
    def get_entry(self, account: str, path: str) -> Optional[Tuple]:
        """Get entry information"""
        try:
            return self.contract.functions.getEntry(account, path).call()
        except Exception as e:
            print(f"Error getting entry: {e}")
            return None
    
    def get_account_paths(self, account: str) -> List[str]:
        """Get all paths for an account"""
        try:
            return self.contract.functions.getAccountPaths(account).call()
        except Exception as e:
            print(f"Error getting account paths: {e}")
            return []
    
    def exists(self, account: str, path: str) -> bool:
        """Check if an entry exists"""
        try:
            return self.contract.functions.exists(account, path).call()
        except Exception as e:
            print(f"Error checking existence: {e}")
            return False
