"""
RPC Proxy Manager for executing off-chain RPC calls described by on-chain plugin contracts.

The two-phase flow:
1. Call contract.getRPCDescriptor(slot) to learn what RPC call to make
2. Execute the RPC call via Web3
3. Call contract.formatRPCResult(slot, rawResult) to get formatted file content
"""
import logging
import time
from typing import Dict, List, Optional, Tuple

from web3 import Web3
from web3.contract import Contract

logger = logging.getLogger(__name__)

# Must match IRPCProxyPlugin.RPCCallType enum order
RPC_CALL_TYPE_STORAGE_AT = 0
RPC_CALL_TYPE_CALL = 1
RPC_CALL_TYPE_GET_CODE = 2
RPC_CALL_TYPE_GAS_PRICE = 3
RPC_CALL_TYPE_BLOCK_NUMBER = 4
RPC_CALL_TYPE_GET_BALANCE = 5

# ABI entries for the IRPCProxyPlugin extension functions
RPC_PROXY_ABI = [
    {
        "inputs": [],
        "name": "isRPCProxy",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "pure",
        "type": "function"
    },
    {
        "inputs": [{"name": "storageSlot", "type": "uint256"}],
        "name": "getRPCDescriptor",
        "outputs": [
            {
                "name": "descriptor",
                "type": "tuple",
                "components": [
                    {"name": "callType", "type": "uint8"},
                    {"name": "targetAddress", "type": "address"},
                    {"name": "callData", "type": "bytes"},
                    {"name": "blockNumber", "type": "uint256"}
                ]
            }
        ],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [
            {"name": "storageSlot", "type": "uint256"},
            {"name": "rpcResult", "type": "bytes"}
        ],
        "name": "formatRPCResult",
        "outputs": [{"name": "formattedContent", "type": "bytes"}],
        "stateMutability": "view",
        "type": "function"
    }
]


class RPCProxyManager:
    """Manages the two-phase RPC proxy read flow for plugin contracts."""

    def __init__(self, w3_pool: List[Web3], cache_ttl: int = 12):
        """
        Args:
            w3_pool: List of Web3 instances for executing RPC calls
            cache_ttl: Cache time-to-live in seconds (default 12, ~1 block)
        """
        self._w3_pool = w3_pool
        self._rr_counter = 0
        self._cache_ttl = cache_ttl
        # Cache: (contract_address, slot) -> (content_bytes, timestamp)
        self._result_cache: Dict[Tuple[str, int], Tuple[bytes, float]] = {}
        # Cache: contract_address -> (is_rpc_proxy, timestamp)
        self._proxy_detection_cache: Dict[str, Tuple[bool, float]] = {}

    def _get_w3(self) -> Web3:
        """Get next Web3 instance via round-robin."""
        idx = self._rr_counter % len(self._w3_pool)
        self._rr_counter += 1
        return self._w3_pool[idx]

    def is_rpc_proxy(self, contract: Contract) -> bool:
        """Check if a contract implements the RPC proxy interface.

        Results are cached per contract address with the same TTL as data.
        """
        address = contract.address
        now = time.time()

        cached = self._proxy_detection_cache.get(address)
        if cached is not None:
            is_proxy, ts = cached
            if now - ts < self._cache_ttl:
                return is_proxy

        try:
            result = contract.functions.isRPCProxy().call()
            self._proxy_detection_cache[address] = (bool(result), now)
            return bool(result)
        except Exception:
            self._proxy_detection_cache[address] = (False, now)
            return False

    def read_proxy_file(self, contract: Contract, slot: int) -> Optional[bytes]:
        """Execute the full RPC proxy read flow for a given slot.

        1. getRPCDescriptor(slot) -> descriptor
        2. Execute the described RPC call
        3. formatRPCResult(slot, rawResult) -> formatted content

        Returns formatted file content bytes, or None on failure.
        """
        address = contract.address
        now = time.time()

        # Check cache
        cache_key = (address, slot)
        cached = self._result_cache.get(cache_key)
        if cached is not None:
            content, ts = cached
            if now - ts < self._cache_ttl:
                return content

        try:
            # Phase 1: Get RPC descriptor
            descriptor = contract.functions.getRPCDescriptor(slot).call()
            call_type, target_address, call_data, block_number = descriptor

            # Phase 2: Execute RPC call
            raw_result = self._execute_rpc(call_type, target_address, call_data, block_number)
            if raw_result is None:
                return None

            # Phase 3: Format result
            formatted = contract.functions.formatRPCResult(slot, raw_result).call()

            # Cache the result
            self._result_cache[cache_key] = (bytes(formatted), time.time())
            return bytes(formatted)
        except Exception as e:
            logger.error(f"RPC proxy read failed for {address} slot {slot}: {e}")
            return None

    def _execute_rpc(self, call_type: int, target_address: str,
                     call_data: bytes, block_number: int) -> Optional[bytes]:
        """Dispatch and execute the RPC call described by the descriptor."""
        w3 = self._get_w3()
        block_id = "latest" if block_number == 0 else block_number

        try:
            if call_type == RPC_CALL_TYPE_STORAGE_AT:
                # call_data is abi.encode(uint256 slot)
                slot = int.from_bytes(call_data[:32], "big")
                result = w3.eth.get_storage_at(target_address, slot, block_id)
                return bytes(result).rjust(32, b'\x00')

            elif call_type == RPC_CALL_TYPE_CALL:
                result = w3.eth.call(
                    {"to": target_address, "data": call_data},
                    block_id
                )
                return bytes(result)

            elif call_type == RPC_CALL_TYPE_GET_CODE:
                result = w3.eth.get_code(target_address, block_id)
                return bytes(result)

            elif call_type == RPC_CALL_TYPE_GAS_PRICE:
                result = w3.eth.gas_price
                return result.to_bytes(32, "big")

            elif call_type == RPC_CALL_TYPE_BLOCK_NUMBER:
                result = w3.eth.block_number
                return result.to_bytes(32, "big")

            elif call_type == RPC_CALL_TYPE_GET_BALANCE:
                result = w3.eth.get_balance(target_address, block_id)
                return result.to_bytes(32, "big")

            else:
                logger.error(f"Unknown RPC call type: {call_type}")
                return None

        except Exception as e:
            logger.error(f"RPC execution failed (type={call_type}): {e}")
            return None
