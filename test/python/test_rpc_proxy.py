"""
Unit tests for RPCProxyManager
"""
import time
import unittest
from unittest.mock import Mock, MagicMock, patch

from fuse_eth_fs.rpc_proxy import (
    RPCProxyManager,
    RPC_CALL_TYPE_STORAGE_AT,
    RPC_CALL_TYPE_CALL,
    RPC_CALL_TYPE_GET_CODE,
    RPC_CALL_TYPE_GAS_PRICE,
    RPC_CALL_TYPE_BLOCK_NUMBER,
    RPC_CALL_TYPE_GET_BALANCE,
)


class TestRPCProxyManagerDetection(unittest.TestCase):
    """Tests for is_rpc_proxy() detection."""

    def setUp(self):
        self.mock_w3 = Mock()
        self.manager = RPCProxyManager([self.mock_w3])

    def test_is_rpc_proxy_true(self):
        contract = Mock()
        contract.address = "0xABC"
        contract.functions.isRPCProxy.return_value.call.return_value = True
        self.assertTrue(self.manager.is_rpc_proxy(contract))

    def test_is_rpc_proxy_false(self):
        contract = Mock()
        contract.address = "0xDEF"
        contract.functions.isRPCProxy.return_value.call.return_value = False
        self.assertFalse(self.manager.is_rpc_proxy(contract))

    def test_is_rpc_proxy_exception_returns_false(self):
        contract = Mock()
        contract.address = "0x123"
        contract.functions.isRPCProxy.return_value.call.side_effect = Exception("not found")
        self.assertFalse(self.manager.is_rpc_proxy(contract))

    def test_is_rpc_proxy_cached(self):
        contract = Mock()
        contract.address = "0xCACHE"
        contract.functions.isRPCProxy.return_value.call.return_value = True

        # Call twice
        self.assertTrue(self.manager.is_rpc_proxy(contract))
        self.assertTrue(self.manager.is_rpc_proxy(contract))

        # Should only call the contract once (cached)
        contract.functions.isRPCProxy.return_value.call.assert_called_once()

    def test_is_rpc_proxy_cache_expires(self):
        contract = Mock()
        contract.address = "0xEXPIRE"
        contract.functions.isRPCProxy.return_value.call.return_value = True

        manager = RPCProxyManager([self.mock_w3], cache_ttl=0)
        manager.is_rpc_proxy(contract)
        manager.is_rpc_proxy(contract)

        # With TTL=0, cache expires immediately so it should call twice
        self.assertEqual(contract.functions.isRPCProxy.return_value.call.call_count, 2)


class TestRPCProxyManagerExecution(unittest.TestCase):
    """Tests for _execute_rpc() dispatch."""

    def setUp(self):
        self.mock_w3 = Mock()
        self.manager = RPCProxyManager([self.mock_w3])

    def test_execute_storage_at(self):
        slot_bytes = (42).to_bytes(32, "big")
        self.mock_w3.eth.get_storage_at.return_value = b'\x00' * 31 + b'\x2a'

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_STORAGE_AT, "0xTARGET", slot_bytes, 0
        )
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 32)
        self.mock_w3.eth.get_storage_at.assert_called_once_with("0xTARGET", 42, "latest")

    def test_execute_storage_at_specific_block(self):
        slot_bytes = (0).to_bytes(32, "big")
        self.mock_w3.eth.get_storage_at.return_value = b'\x00' * 32

        self.manager._execute_rpc(
            RPC_CALL_TYPE_STORAGE_AT, "0xTARGET", slot_bytes, 100
        )
        self.mock_w3.eth.get_storage_at.assert_called_once_with("0xTARGET", 0, 100)

    def test_execute_call(self):
        call_data = b'\xde\xad\xbe\xef'
        self.mock_w3.eth.call.return_value = b'\x01\x02\x03'

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_CALL, "0xTARGET", call_data, 0
        )
        self.assertEqual(result, b'\x01\x02\x03')
        self.mock_w3.eth.call.assert_called_once_with(
            {"to": "0xTARGET", "data": call_data}, "latest"
        )

    def test_execute_get_code(self):
        self.mock_w3.eth.get_code.return_value = b'\x60\x80\x60\x40'

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_GET_CODE, "0xTARGET", b'', 0
        )
        self.assertEqual(result, b'\x60\x80\x60\x40')

    def test_execute_gas_price(self):
        self.mock_w3.eth.gas_price = 20_000_000_000  # 20 gwei

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_GAS_PRICE, "0x0", b'', 0
        )
        self.assertEqual(len(result), 32)
        self.assertEqual(int.from_bytes(result, "big"), 20_000_000_000)

    def test_execute_block_number(self):
        self.mock_w3.eth.block_number = 12345678

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_BLOCK_NUMBER, "0x0", b'', 0
        )
        self.assertEqual(len(result), 32)
        self.assertEqual(int.from_bytes(result, "big"), 12345678)

    def test_execute_get_balance(self):
        self.mock_w3.eth.get_balance.return_value = 10**18  # 1 ETH

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_GET_BALANCE, "0xTARGET", b'', 0
        )
        self.assertEqual(len(result), 32)
        self.assertEqual(int.from_bytes(result, "big"), 10**18)

    def test_execute_unknown_type_returns_none(self):
        result = self.manager._execute_rpc(99, "0x0", b'', 0)
        self.assertIsNone(result)

    def test_execute_rpc_exception_returns_none(self):
        self.mock_w3.eth.get_storage_at.side_effect = Exception("rpc error")
        slot_bytes = (0).to_bytes(32, "big")

        result = self.manager._execute_rpc(
            RPC_CALL_TYPE_STORAGE_AT, "0xTARGET", slot_bytes, 0
        )
        self.assertIsNone(result)


class TestRPCProxyManagerReadFlow(unittest.TestCase):
    """Tests for the full read_proxy_file() flow."""

    def setUp(self):
        self.mock_w3 = Mock()
        self.manager = RPCProxyManager([self.mock_w3])

    def _make_contract(self, address="0xPLUGIN"):
        contract = Mock()
        contract.address = address
        return contract

    def test_read_proxy_file_full_flow(self):
        contract = self._make_contract()

        # getRPCDescriptor returns STORAGE_AT descriptor
        slot_data = (0).to_bytes(32, "big")
        contract.functions.getRPCDescriptor.return_value.call.return_value = (
            RPC_CALL_TYPE_STORAGE_AT,  # callType
            "0xTARGET",                # targetAddress
            slot_data,                 # callData
            0                          # blockNumber (latest)
        )

        # Mock the RPC call
        self.mock_w3.eth.get_storage_at.return_value = b'\x00' * 31 + b'\x2a'

        # formatRPCResult returns formatted content
        formatted = b"Storage Slot: 0\nValue: 42\n"
        contract.functions.formatRPCResult.return_value.call.return_value = formatted

        result = self.manager.read_proxy_file(contract, 0)

        self.assertEqual(result, formatted)
        contract.functions.getRPCDescriptor.assert_called_once_with(0)
        contract.functions.formatRPCResult.assert_called_once()

    def test_read_proxy_file_cached(self):
        contract = self._make_contract()

        slot_data = (0).to_bytes(32, "big")
        contract.functions.getRPCDescriptor.return_value.call.return_value = (
            RPC_CALL_TYPE_STORAGE_AT, "0xTARGET", slot_data, 0
        )
        self.mock_w3.eth.get_storage_at.return_value = b'\x00' * 32
        contract.functions.formatRPCResult.return_value.call.return_value = b"cached"

        # Call twice
        result1 = self.manager.read_proxy_file(contract, 0)
        result2 = self.manager.read_proxy_file(contract, 0)

        self.assertEqual(result1, result2)
        # getRPCDescriptor should only be called once (cached)
        contract.functions.getRPCDescriptor.return_value.call.assert_called_once()

    def test_read_proxy_file_rpc_failure_returns_none(self):
        contract = self._make_contract()

        slot_data = (0).to_bytes(32, "big")
        contract.functions.getRPCDescriptor.return_value.call.return_value = (
            RPC_CALL_TYPE_STORAGE_AT, "0xTARGET", slot_data, 0
        )
        self.mock_w3.eth.get_storage_at.side_effect = Exception("node down")

        result = self.manager.read_proxy_file(contract, 0)
        self.assertIsNone(result)

    def test_read_proxy_file_descriptor_failure_returns_none(self):
        contract = self._make_contract()
        contract.functions.getRPCDescriptor.return_value.call.side_effect = Exception("bad slot")

        result = self.manager.read_proxy_file(contract, 99)
        self.assertIsNone(result)


class TestRPCProxyManagerRoundRobin(unittest.TestCase):
    """Tests for round-robin Web3 pool usage."""

    def test_round_robin_across_pool(self):
        w3_1 = Mock()
        w3_2 = Mock()
        manager = RPCProxyManager([w3_1, w3_2])

        # First call should use w3_1
        w3_1.eth.gas_price = 100
        result1 = manager._execute_rpc(RPC_CALL_TYPE_GAS_PRICE, "0x0", b'', 0)

        # Second call should use w3_2
        w3_2.eth.gas_price = 200
        result2 = manager._execute_rpc(RPC_CALL_TYPE_GAS_PRICE, "0x0", b'', 0)

        self.assertEqual(int.from_bytes(result1, "big"), 100)
        self.assertEqual(int.from_bytes(result2, "big"), 200)


if __name__ == '__main__':
    unittest.main()
