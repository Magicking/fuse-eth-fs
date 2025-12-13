"""
Unit tests for PRIVATE_KEY functionality in FUSE filesystem
Tests file, directory, subdirectory, and nested file operations with private key signing
"""
import os
import unittest
from unittest.mock import Mock, patch, MagicMock, call
from eth_account import Account
from fuse_eth_fs.contract_manager import ContractManager
from fuse_eth_fs.filesystem import EthFS


class TestPrivateKeyFunctionality(unittest.TestCase):
    """Test PRIVATE_KEY environment variable functionality"""
    
    def setUp(self):
        """Set up test fixtures"""
        # Generate a test private key and account
        self.test_private_key = '0x' + '1' * 64  # Dummy private key for testing
        self.test_account = Account.from_key(self.test_private_key[2:])
        self.test_account_address = self.test_account.address
        
        # Mock Web3 instance
        self.mock_w3 = Mock()
        self.mock_w3.eth.chain_id = 1337
        self.mock_w3.eth.gas_price = 1000000000
        self.mock_w3.eth.get_transaction_count.return_value = 0
        self.mock_w3.eth.send_raw_transaction.return_value = b'0x' + b'1' * 32
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = {'status': 1}
        
        # Mock contract
        self.mock_contract = Mock()
        self.mock_contract.functions.getEntries.return_value.call.return_value = []
        
        # Mock contract factory
        with patch.object(self.mock_w3.eth, 'contract', return_value=self.mock_contract):
            self.manager = ContractManager(
                self.mock_w3,
                '0x1234567890abcdef1234567890abcdef12345678',
                transaction_account=self.test_account
            )
    
    def test_contract_manager_with_private_key(self):
        """Test ContractManager initializes with transaction account"""
        self.assertIsNotNone(self.manager.transaction_account)
        self.assertEqual(self.manager.transaction_account.address, self.test_account_address)
    
    def test_create_file_with_private_key(self):
        """Test file creation with PRIVATE_KEY signing"""
        # Setup mocks
        mock_tx_hash = b'0x' + b'1' * 32
        existing_slots = set([0, 1])
        new_slots = set([0, 1, 2])
        
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),  # Before creation
            list(new_slots)  # After creation
        ]
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.createFile.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            result = self.manager.create_file('test.txt', b'Hello World', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.createFile.assert_called_once_with(
            b'test.txt', b'Hello World', 0
        )
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_create_directory_with_private_key(self):
        """Test directory creation with PRIVATE_KEY signing"""
        # Setup mocks
        mock_tx_hash = b'0x' + b'1' * 32
        existing_slots = set([0])
        new_slots = set([0, 1])
        
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),
            list(new_slots)
        ]
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.createDirectory.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            result = self.manager.create_directory('mydir', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.createDirectory.assert_called_once()
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_create_subdirectory_with_private_key(self):
        """Test subdirectory creation with PRIVATE_KEY signing"""
        # Setup mocks
        mock_tx_hash = b'0x' + b'1' * 32
        existing_slots = set([0])
        new_slots = set([0, 1])
        
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),
            list(new_slots)
        ]
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.createDirectory.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            # Create nested directory: parent/child
            result = self.manager.create_directory('parent/child', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.createDirectory.assert_called()
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
    
    def test_create_nested_file_in_subdirectory_with_private_key(self):
        """Test creating nested file in subdirectory with PRIVATE_KEY signing"""
        # Setup mocks
        mock_tx_hash = b'0x' + b'1' * 32
        existing_slots = set([0, 1])  # Directory already exists
        new_slots = set([0, 1, 2])  # New file slot
        
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),
            list(new_slots)
        ]
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.createFile.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            # Create file in subdirectory: parent/child/file.txt
            result = self.manager.create_file('parent/child/file.txt', b'Nested content', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.createFile.assert_called_once_with(
            b'parent/child/file.txt', b'Nested content', 0
        )
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_update_file_with_private_key(self):
        """Test file update with PRIVATE_KEY signing"""
        # Setup mocks - file exists at slot 1
        mock_tx_hash = b'0x' + b'1' * 32
        
        # Mock finding the file slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'old content', 1234567890, True, 12,
            '0x0000000000000000000000000000000000000000'
        )
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.updateFile.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            result = self.manager.update_file('test.txt', b'new content', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.updateFile.assert_called_once()
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_write_file_with_private_key(self):
        """Test file write with PRIVATE_KEY signing"""
        # Setup mocks - file exists at slot 1
        mock_tx_hash = b'0x' + b'1' * 32
        
        # Mock finding the file slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'existing', 1234567890, True, 8,
            '0x0000000000000000000000000000000000000000'
        )
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.writeFile.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            result = self.manager.write_file('test.txt', b'appended', 8, '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.writeFile.assert_called_once()
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_delete_entry_with_private_key(self):
        """Test entry deletion with PRIVATE_KEY signing"""
        # Setup mocks - file exists at slot 1
        mock_tx_hash = b'0x' + b'1' * 32
        
        # Mock finding the file slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'content', 1234567890, True, 7,
            '0x0000000000000000000000000000000000000000'
        )
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.deleteEntry.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx) as mock_sign:
            result = self.manager.delete_entry('test.txt', '0xuser')
        
        # Verify transaction was signed and sent
        self.assertTrue(result)
        self.mock_contract.functions.deleteEntry.assert_called_once()
        mock_function_call.build_transaction.assert_called_once()
        mock_sign.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_called_once()
    
    def test_transaction_uses_account_address(self):
        """Test that transactions use the transaction account address, not the path account"""
        # Setup mocks
        mock_tx_hash = b'0x' + b'1' * 32
        existing_slots = set([0])
        new_slots = set([0, 1])
        
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),
            list(new_slots)
        ]
        
        # Mock function call chain
        mock_function_call = Mock()
        mock_build_tx = {
            'to': self.manager.contract_address,
            'data': b'0x1234',
            'gas': 100000,
            'gasPrice': 1000000000,
            'nonce': 0,
            'chainId': 1337
        }
        mock_function_call.build_transaction.return_value = mock_build_tx
        mock_function_call.estimate_gas.return_value = 100000
        
        self.mock_contract.functions.createFile.return_value = mock_function_call
        self.mock_w3.eth.send_raw_transaction.return_value = mock_tx_hash
        
        # Mock signed transaction
        mock_signed_tx = Mock()
        mock_signed_tx.rawTransaction = b'0xsigned'
        with patch.object(self.manager.transaction_account, 'sign_transaction', return_value=mock_signed_tx):
            # Call with a different account address in path
            path_account = '0x' + '2' * 40  # Different from transaction account
            result = self.manager.create_file('test.txt', b'content', path_account)
        
        # Verify that build_transaction was called with transaction account address
        self.assertTrue(result)
        call_args = mock_function_call.build_transaction.call_args[0][0]
        self.assertEqual(call_args['from'], self.test_account_address)
        self.assertNotEqual(call_args['from'], path_account)
    
    def test_fallback_when_no_private_key(self):
        """Test that system falls back to default behavior when no PRIVATE_KEY is set"""
        # Create manager without transaction account
        with patch.object(self.mock_w3.eth, 'contract', return_value=self.mock_contract):
            manager_no_key = ContractManager(
                self.mock_w3,
                '0x1234567890abcdef1234567890abcdef12345678',
                transaction_account=None
            )
        
        self.assertIsNone(manager_no_key.transaction_account)
        
        # Mock transact method (fallback behavior)
        mock_tx_hash = b'0x' + b'1' * 32
        mock_function_call = Mock()
        mock_function_call.transact.return_value = mock_tx_hash
        self.mock_contract.functions.createFile.return_value = mock_function_call
        
        existing_slots = set([0])
        new_slots = set([0, 1])
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            list(existing_slots),
            list(new_slots)
        ]
        
        result = manager_no_key.create_file('test.txt', b'content', '0xuser')
        
        # Verify transact was called (not send_raw_transaction)
        self.assertTrue(result)
        mock_function_call.transact.assert_called_once()
        self.mock_w3.eth.send_raw_transaction.assert_not_called()


class TestFilesystemWithPrivateKey(unittest.TestCase):
    """Test EthFS initialization with PRIVATE_KEY"""
    
    def setUp(self):
        """Set up test fixtures"""
        self.test_private_key = '0x' + '1' * 64
        self.test_account = Account.from_key(self.test_private_key[2:])
        
        # Mock RPCManager
        self.mock_w3 = Mock()
        self.mock_w3.eth.chain_id = 1337
        self.mock_w3.is_connected.return_value = True
    
    @patch('fuse_eth_fs.filesystem.RPCManager')
    @patch.dict(os.environ, {'PRIVATE_KEY': '1111111111111111111111111111111111111111111111111111111111111111'})
    def test_filesystem_loads_private_key(self, mock_rpc_manager_class):
        """Test that EthFS loads PRIVATE_KEY from environment"""
        # Setup RPCManager mock
        mock_rpc_manager = Mock()
        mock_rpc_manager.get_connection.return_value = self.mock_w3
        mock_rpc_manager_class.return_value = mock_rpc_manager
        
        # Mock contract
        mock_contract = Mock()
        mock_contract.functions.getEntries.return_value.call.return_value = []
        with patch.object(self.mock_w3.eth, 'contract', return_value=mock_contract):
            fs = EthFS({1337: '0x1234567890abcdef1234567890abcdef12345678'})
        
        # Verify transaction account was loaded
        self.assertIsNotNone(fs.transaction_account)
        self.assertEqual(fs.transaction_account.address, self.test_account.address)
    
    @patch('fuse_eth_fs.filesystem.RPCManager')
    @patch.dict(os.environ, {}, clear=True)
    def test_filesystem_without_private_key(self, mock_rpc_manager_class):
        """Test that EthFS works without PRIVATE_KEY (fallback mode)"""
        # Setup RPCManager mock
        mock_rpc_manager = Mock()
        mock_rpc_manager.get_connection.return_value = self.mock_w3
        mock_rpc_manager_class.return_value = mock_rpc_manager
        
        # Mock contract
        mock_contract = Mock()
        mock_contract.functions.getEntries.return_value.call.return_value = []
        with patch.object(self.mock_w3.eth, 'contract', return_value=mock_contract):
            fs = EthFS({1337: '0x1234567890abcdef1234567890abcdef12345678'})
        
        # Verify transaction account is None
        self.assertIsNone(fs.transaction_account)
    
    @patch('fuse_eth_fs.filesystem.RPCManager')
    @patch.dict(os.environ, {'PRIVATE_KEY': '0x1111111111111111111111111111111111111111111111111111111111111111'})
    def test_filesystem_with_0x_prefix_private_key(self, mock_rpc_manager_class):
        """Test that EthFS handles private key with 0x prefix"""
        # Setup RPCManager mock
        mock_rpc_manager = Mock()
        mock_rpc_manager.get_connection.return_value = self.mock_w3
        mock_rpc_manager_class.return_value = mock_rpc_manager
        
        # Mock contract
        mock_contract = Mock()
        mock_contract.functions.getEntries.return_value.call.return_value = []
        with patch.object(self.mock_w3.eth, 'contract', return_value=mock_contract):
            fs = EthFS({1337: '0x1234567890abcdef1234567890abcdef12345678'})
        
        # Verify transaction account was loaded (0x prefix should be handled)
        self.assertIsNotNone(fs.transaction_account)
        self.assertEqual(fs.transaction_account.address, self.test_account.address)


if __name__ == '__main__':
    unittest.main()

