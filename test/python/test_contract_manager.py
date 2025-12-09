"""
Unit tests for ContractManager
"""
import unittest
from unittest.mock import Mock, patch, MagicMock, call
from fuse_eth_fs.contract_manager import ContractManager


class TestContractManager(unittest.TestCase):
    
    def setUp(self):
        """Set up test fixtures"""
        self.mock_w3 = Mock()
        self.mock_contract = Mock()
        
        # Mock the contract factory
        with patch.object(self.mock_w3.eth, 'contract', return_value=self.mock_contract):
            self.manager = ContractManager(
                self.mock_w3,
                '0x1234567890abcdef1234567890abcdef12345678'
            )
    
    def test_create_file_success(self):
        """Test successful file creation"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        self.mock_contract.functions.createFile.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.create_file('test.txt', b'content', '0xuser')
        
        self.assertTrue(result)
        self.mock_contract.functions.createFile.assert_called_once_with('test.txt', b'content')
    
    def test_create_file_failure(self):
        """Test file creation failure"""
        self.mock_contract.functions.createFile.return_value.transact.side_effect = Exception("Transaction failed")
        
        result = self.manager.create_file('test.txt', b'content', '0xuser')
        
        self.assertFalse(result)
    
    def test_create_directory_success(self):
        """Test successful directory creation"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        self.mock_contract.functions.createDirectory.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.create_directory('mydir', '0xuser')
        
        self.assertTrue(result)
        self.mock_contract.functions.createDirectory.assert_called_once_with('mydir')
    
    def test_update_file_success(self):
        """Test successful file update"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        self.mock_contract.functions.updateFile.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.update_file('test.txt', b'new content', '0xuser')
        
        self.assertTrue(result)
        self.mock_contract.functions.updateFile.assert_called_once_with('test.txt', b'new content')
    
    def test_delete_entry_success(self):
        """Test successful entry deletion"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        self.mock_contract.functions.deleteEntry.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.delete_entry('test.txt', '0xuser')
        
        self.assertTrue(result)
        self.mock_contract.functions.deleteEntry.assert_called_once_with('test.txt')
    
    def test_get_entry(self):
        """Test getting entry information"""
        expected_entry = (
            'test.txt',  # name
            0,           # entryType (FILE)
            '0xuser',    # owner
            b'content',  # content
            1234567890,  # timestamp
            True         # exists
        )
        
        self.mock_contract.functions.getEntry.return_value.call.return_value = expected_entry
        
        result = self.manager.get_entry('0xuser', 'test.txt')
        
        self.assertEqual(result, expected_entry)
        self.mock_contract.functions.getEntry.assert_called_once_with('0xuser', 'test.txt')
    
    def test_get_entry_failure(self):
        """Test getting entry when call fails"""
        self.mock_contract.functions.getEntry.return_value.call.side_effect = Exception("Call failed")
        
        result = self.manager.get_entry('0xuser', 'test.txt')
        
        self.assertIsNone(result)
    
    def test_get_account_paths(self):
        """Test getting all paths for an account"""
        expected_paths = ['file1.txt', 'file2.txt', 'dir1']
        
        self.mock_contract.functions.getAccountPaths.return_value.call.return_value = expected_paths
        
        result = self.manager.get_account_paths('0xuser')
        
        self.assertEqual(result, expected_paths)
        self.mock_contract.functions.getAccountPaths.assert_called_once_with('0xuser')
    
    def test_exists_true(self):
        """Test checking if entry exists (true case)"""
        self.mock_contract.functions.exists.return_value.call.return_value = True
        
        result = self.manager.exists('0xuser', 'test.txt')
        
        self.assertTrue(result)
        self.mock_contract.functions.exists.assert_called_once_with('0xuser', 'test.txt')
    
    def test_exists_false(self):
        """Test checking if entry exists (false case)"""
        self.mock_contract.functions.exists.return_value.call.return_value = False
        
        result = self.manager.exists('0xuser', 'nonexistent.txt')
        
        self.assertFalse(result)


if __name__ == '__main__':
    unittest.main()
