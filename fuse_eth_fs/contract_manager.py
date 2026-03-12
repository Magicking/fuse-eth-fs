"""
Contract Manager for interacting with the FileSystem smart contract
"""
import json
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, List, Tuple, Dict, Generator, Union
from web3 import Web3
from web3.contract import Contract
from eth_account import Account

from .rpc_proxy import RPCProxyManager, RPC_PROXY_ABI

logger = logging.getLogger(__name__)

# Default ABI matching IFileSystem.sol interface
DEFAULT_ABI = [
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
    },
    {
        "inputs": [],
        "name": "getEntryCount",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [
            {"name": "offset", "type": "uint256"},
            {"name": "limit", "type": "uint256"}
        ],
        "name": "getEntriesPaginated",
        "outputs": [{"name": "", "type": "uint256[]"}],
        "stateMutability": "view",
        "type": "function"
    }
]


class ContractManager:
    """Manages interactions with the FileSystem smart contract"""

    def __init__(self, w3: Union[Web3, List[Web3]], contract_address: str, abi_path: Optional[str] = None, transaction_account: Optional[Account] = None):
        """
        Initialize the contract manager

        Args:
            w3: Web3 instance or list of Web3 instances (pool)
            contract_address: Address of the deployed FileSystem contract
            abi_path: Path to the contract ABI JSON file (optional)
            transaction_account: Account to use for signing transactions (optional)
        """
        # Normalize to list
        if isinstance(w3, list):
            self._w3_pool: List[Web3] = list(w3)
        else:
            self._w3_pool = [w3]

        self.contract_address = Web3.to_checksum_address(contract_address)
        self.transaction_account = transaction_account
        self._rr_counter = 0

        # Path to storage slot mapping per account (starting from 0)
        self.path_to_slot: Dict[tuple, int] = {}
        self.slot_to_path: Dict[tuple, str] = {}
        self.next_slot: Dict[str, int] = {}

        # Load ABI
        if abi_path:
            with open(abi_path, 'r') as f:
                abi = json.load(f)
        else:
            abi = DEFAULT_ABI

        # Merge RPC proxy ABI entries so contracts can be queried for proxy methods
        merged_abi = list(abi) + RPC_PROXY_ABI
        self._abi = merged_abi

        # Create contract instances for each Web3 in the pool
        self.contracts: List[Contract] = []
        for w3_instance in self._w3_pool:
            self.contracts.append(w3_instance.eth.contract(
                address=self.contract_address,
                abi=merged_abi
            ))

        # Primary Web3/contract for writes (first in pool)
        self.w3 = self._w3_pool[0]
        self.contract: Contract = self.contracts[0]

        # RPC proxy manager (lazy: detection is cached per address)
        self.rpc_proxy_manager = RPCProxyManager(self._w3_pool)
        self._is_rpc_proxy: Optional[bool] = None

    def _get_contract(self) -> Contract:
        """Get a contract instance via round-robin for read operations"""
        idx = self._rr_counter % len(self.contracts)
        self._rr_counter += 1
        return self.contracts[idx]

    def _get_w3(self) -> Web3:
        """Get the Web3 instance corresponding to the current round-robin contract"""
        idx = (self._rr_counter - 1) % len(self._w3_pool)
        return self._w3_pool[idx]

    @property
    def pool_size(self) -> int:
        """Number of Web3/contract instances in the pool"""
        return len(self.contracts)

    def is_rpc_proxy_plugin(self) -> bool:
        """Check if this contract is an RPC proxy plugin (result is cached)."""
        if self._is_rpc_proxy is None:
            self._is_rpc_proxy = self.rpc_proxy_manager.is_rpc_proxy(self.contract)
        return self._is_rpc_proxy

    def _send_transaction(self, function_call, tx_params: dict) -> str:
        """
        Send a transaction, signing it with the transaction_account if available.
        Always uses the primary (first) Web3 instance for writes.
        """
        if self.transaction_account:
            tx_params_with_account = tx_params.copy()
            tx_params_with_account['from'] = self.transaction_account.address

            tx = function_call.build_transaction(tx_params_with_account)

            if 'nonce' not in tx:
                tx['nonce'] = self.w3.eth.get_transaction_count(self.transaction_account.address)

            if 'chainId' not in tx:
                tx['chainId'] = self.w3.eth.chain_id

            if 'gasPrice' not in tx and 'maxFeePerGas' not in tx:
                tx['gasPrice'] = self.w3.eth.gas_price

            if 'gas' not in tx:
                try:
                    tx['gas'] = function_call.estimate_gas(tx_params_with_account)
                except Exception as e:
                    logger.warning(f"Could not estimate gas, using default: {e}")
                    tx['gas'] = 100000

            signed_tx = self.transaction_account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
            return tx_hash
        else:
            return function_call.transact(tx_params)

    def _get_storage_slot(self, account: str, path: str) -> int:
        """Get storage slot for a path."""
        key = (account.lower(), path)

        if key in self.path_to_slot:
            return self.path_to_slot[key]

        slot = self._find_slot_by_path(account, path)
        if slot is not None:
            return slot

        raise ValueError(f"Storage slot not found for path '{path}' - entry may not exist")

    def _get_path_from_slot(self, account: str, slot: int) -> Optional[str]:
        """Get path from storage slot"""
        return self.slot_to_path.get((account.lower(), slot))

    def _find_slot_by_path(self, account: str, path: str, any_owner: bool = False) -> Optional[int]:
        """
        Find storage slot for a path by querying all entries and matching by name.
        Uses round-robin contract for reads.
        """
        try:
            contract = self._get_contract()
            slots = contract.functions.getEntries().call()
            path_bytes = path.encode('utf-8')

            for slot in slots:
                try:
                    read_contract = self._get_contract()
                    entry = read_contract.functions.getEntry(slot).call()
                    entry_type, owner, name_bytes, body, timestamp, exists, file_size, dir_target = entry

                    if exists and (any_owner or owner.lower() == account.lower()):
                        if (entry_type == 0 or entry_type == 1) and name_bytes == path_bytes:
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

    def parallel_get_entries(self, slots: List[int], max_workers: Optional[int] = None) -> Dict[int, tuple]:
        """
        Fetch multiple entries in parallel using ThreadPoolExecutor.

        Args:
            slots: List of storage slot IDs to fetch
            max_workers: Max parallel workers (defaults to pool size, capped at 8)

        Returns:
            Dict mapping slot -> entry tuple for entries that exist
        """
        if not slots:
            return {}

        if max_workers is None:
            max_workers = min(self.pool_size, 8)
        max_workers = max(1, min(max_workers, 8))

        results: Dict[int, tuple] = {}

        def fetch_entry(slot: int) -> Tuple[int, Optional[tuple]]:
            try:
                contract = self._get_contract()
                entry = contract.functions.getEntry(slot).call()
                return (slot, entry)
            except Exception as e:
                logger.debug(f"Error fetching entry for slot {slot}: {e}")
                return (slot, None)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {executor.submit(fetch_entry, slot): slot for slot in slots}
            for future in as_completed(futures):
                slot, entry = future.result()
                if entry is not None:
                    results[slot] = entry

        return results

    def create_file(self, path: str, body: bytes, account: str) -> bool:
        """Create a file in the contract storage (storage slot auto-assigned)"""
        try:
            existing_slots = set(self.contract.functions.getEntries().call())

            name_bytes = path.encode('utf-8')

            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.createFile(name_bytes, body, 0),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)

            new_slots = set(self.contract.functions.getEntries().call())
            new_slot = (new_slots - existing_slots).pop() if (new_slots - existing_slots) else None

            if new_slot is not None:
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
        """Create a directory in the contract storage (storage slot auto-assigned)."""
        try:
            existing_slots = set(self.contract.functions.getEntries().call())

            name_bytes = path.encode('utf-8')

            if target_address is None:
                target_address = "0x0000000000000000000000000000000000000000"

            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.createDirectory(name_bytes, target_address),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)

            new_slots = set(self.contract.functions.getEntries().call())
            new_slot = (new_slots - existing_slots).pop() if (new_slots - existing_slots) else None

            if new_slot is not None:
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
            from_address = self.transaction_account.address if self.transaction_account else account
            tx_hash = self._send_transaction(
                self.contract.functions.deleteEntry(storage_slot),
                {'from': from_address}
            )
            self.w3.eth.wait_for_transaction_receipt(tx_hash)
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
            contract = self._get_contract()
            result = contract.functions.getEntry(storage_slot).call()
            return result
        except Exception as e:
            logger.debug(f"Error getting entry '{path}' for account {account}: {e}")
            return None

    def get_account_paths(self, account: str) -> List[str]:
        """Get all paths for an account by querying all storage slots"""
        try:
            contract = self._get_contract()
            slots = contract.functions.getEntries().call()

            # Use parallel fetch for entries
            entries = self.parallel_get_entries(slots)

            paths = []
            account_lower = account.lower()
            for slot, entry in entries.items():
                entry_type, owner, name, body, timestamp, exists, file_size, dir_target = entry
                if exists and owner.lower() == account_lower:
                    path = self._get_path_from_slot(account, slot)
                    if path:
                        paths.append(path)

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
            contract = self._get_contract()
            return contract.functions.exists(storage_slot).call()
        except Exception as e:
            logger.debug(f"Error checking existence of '{path}' for account {account}: {e}")
            return False

    def write_file(self, path: str, body: bytes, offset: int, account: str) -> bool:
        """Write file body at a specific offset (creates file if it doesn't exist)"""
        try:
            storage_slot = self._find_slot_by_path(account, path)

            if storage_slot is None:
                return self.create_file(path, body, account)

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

            if self.is_rpc_proxy_plugin():
                # Two-phase RPC proxy read
                full_content = self.rpc_proxy_manager.read_proxy_file(
                    self._get_contract(), storage_slot
                )
                if full_content is None:
                    return None
                if length:
                    return full_content[offset:offset + length]
                return full_content[offset:]

            contract = self._get_contract()
            result = contract.functions.readFile(storage_slot, offset, length).call()
            return result
        except Exception as e:
            logger.error(f"Error reading file '{path}' for account {account}: {e}")
            return None

    def get_entry_count(self) -> int:
        """Get the total number of entries in the filesystem"""
        try:
            contract = self._get_contract()
            return contract.functions.getEntryCount().call()
        except Exception as e:
            logger.error(f"Error getting entry count: {e}")
            return 0

    def get_entries_paginated(self, offset: int, limit: int) -> List[int]:
        """Get a paginated slice of storage slots that have entries"""
        try:
            contract = self._get_contract()
            return contract.functions.getEntriesPaginated(offset, limit).call()
        except Exception as e:
            logger.error(f"Error getting paginated entries (offset={offset}, limit={limit}): {e}")
            return []

    def iter_entries(self, page_size: int = 50) -> Generator[int, None, None]:
        """Iterate over all entry storage slots in pages"""
        total = self.get_entry_count()
        offset = 0
        while offset < total:
            slots = self.get_entries_paginated(offset, page_size)
            if not slots:
                break
            for slot in slots:
                yield slot
            offset += len(slots)

    def read_file_chunked(self, path: str, chunk_size: int, account: str) -> Generator[bytes, None, None]:
        """Read a file in chunks, yielding each chunk"""
        storage_slot = self._find_slot_by_path(account, path, any_owner=True)
        if storage_slot is None:
            return

        try:
            contract = self._get_contract()
            entry = contract.functions.getEntry(storage_slot).call()
            file_size = entry[6]
        except Exception as e:
            logger.error(f"Error getting file size for '{path}': {e}")
            return

        offset = 0
        while offset < file_size:
            length = min(chunk_size, file_size - offset)
            try:
                contract = self._get_contract()
                chunk = contract.functions.readFile(storage_slot, offset, length).call()
                if not chunk:
                    break
                yield chunk
                offset += len(chunk)
            except Exception as e:
                logger.error(f"Error reading chunk at offset {offset} for '{path}': {e}")
                break
