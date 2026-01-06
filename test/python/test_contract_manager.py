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
        
        # Mock getEntries to return different sets before/after creation
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            [0, 1],  # Before: existing slots
            [0, 1, 2]  # After: new slot 2 added
        ]
        self.mock_contract.functions.createFile.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.create_file('test.txt', b'content', '0xuser')
        
        self.assertTrue(result)
        # Should be called with full path as name, body, and offset (0)
        self.mock_contract.functions.createFile.assert_called_once_with(b'test.txt', b'content', 0)
    
    def test_create_file_failure(self):
        """Test file creation failure"""
        self.mock_contract.functions.createFile.return_value.transact.side_effect = Exception("Transaction failed")
        
        result = self.manager.create_file('test.txt', b'content', '0xuser')
        
        self.assertFalse(result)
    
    def test_create_directory_success(self):
        """Test successful directory creation"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        # Mock getEntries to return different sets before/after creation
        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            [0, 1],  # Before: existing slots
            [0, 1, 2]  # After: new slot 2 added
        ]
        self.mock_contract.functions.createDirectory.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.create_directory('mydir', '0xuser')
        
        self.assertTrue(result)
        # Should be called with directory path and default target address (address(0))
        self.mock_contract.functions.createDirectory.assert_called_once_with(
            b'mydir', 
            '0x0000000000000000000000000000000000000000'
        )
    
    def test_update_file_success(self):
        """Test successful file update"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        # Mock getEntry to return entry with matching name
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'old content', 1234567890, True, 12, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.updateFile.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.update_file('test.txt', b'new content', '0xuser')
        
        self.assertTrue(result)
        # Should be called with storage slot found by path, body, and offset (0)
        self.mock_contract.functions.updateFile.assert_called_once()
        call_args = self.mock_contract.functions.updateFile.call_args[0]
        self.assertEqual(call_args[1], b'new content')
        self.assertEqual(call_args[2], 0)
    
    def test_delete_entry_success(self):
        """Test successful entry deletion"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}
        
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        # Mock getEntry to return entry with matching name
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'content', 1234567890, True, 7, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.deleteEntry.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt
        
        result = self.manager.delete_entry('test.txt', '0xuser')
        
        self.assertTrue(result)
        # Should be called with storage slot found by path
        self.mock_contract.functions.deleteEntry.assert_called_once()
    
    def test_get_entry(self):
        """Test getting entry information"""
        expected_entry = (
            0,           # entryType (FILE)
            '0xuser',    # owner
            b'test.txt', # name
            b'content',  # body
            1234567890,  # timestamp
            True,        # entryExists
            7,           # fileSize
            '0x0000000000000000000000000000000000000000'  # directoryTarget
        )
        
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        # Mock getEntry to return entry with matching name for slot 0
        self.mock_contract.functions.getEntry.return_value.call.return_value = expected_entry
        
        result = self.manager.get_entry('0xuser', 'test.txt')
        
        self.assertEqual(result, expected_entry)
        # Should be called with storage slot found by path
        self.mock_contract.functions.getEntry.assert_called()
    
    def test_get_entry_failure(self):
        """Test getting entry when call fails"""
        self.mock_contract.functions.getEntry.return_value.call.side_effect = Exception("Call failed")
        
        result = self.manager.get_entry('0xuser', 'test.txt')
        
        self.assertIsNone(result)
    
    def test_get_account_paths(self):
        """Test getting all paths for an account"""
        # Mock getEntries to return storage slots
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        
        # Mock getEntry for each slot to return entry info
        def mock_get_entry(slot):
            mock_entry = Mock()
            if slot == 0:
                mock_entry.call.return_value = (0, '0xuser', b'file1.txt', b'content1', 1234567890, True, 8, '0x0000000000000000000000000000000000000000')
            elif slot == 1:
                mock_entry.call.return_value = (0, '0xuser', b'file2.txt', b'content2', 1234567890, True, 8, '0x0000000000000000000000000000000000000000')
            elif slot == 2:
                mock_entry.call.return_value = (1, '0xuser', b'', b'', 1234567890, True, 0, '0x0000000000000000000000000000000000000000')
            return mock_entry
        
        self.mock_contract.functions.getEntry.side_effect = mock_get_entry
        
        # Set up path mappings
        self.manager.path_to_slot[('0xuser', 'file1.txt')] = 0
        self.manager.slot_to_path[('0xuser', 0)] = 'file1.txt'
        self.manager.path_to_slot[('0xuser', 'file2.txt')] = 1
        self.manager.slot_to_path[('0xuser', 1)] = 'file2.txt'
        self.manager.path_to_slot[('0xuser', 'dir1')] = 2
        self.manager.slot_to_path[('0xuser', 2)] = 'dir1'
        
        result = self.manager.get_account_paths('0xuser')
        
        # Should return paths that we have mappings for
        self.assertIn('file1.txt', result)
        self.assertIn('file2.txt', result)
        self.assertIn('dir1', result)
        self.mock_contract.functions.getEntries.assert_called_once()
    
    def test_exists_true(self):
        """Test checking if entry exists (true case)"""
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        # Mock getEntry to return entry with matching name
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'content', 1234567890, True, 7, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.exists.return_value.call.return_value = True
        
        result = self.manager.exists('0xuser', 'test.txt')
        
        self.assertTrue(result)
        # Should be called with storage slot found by path
        self.mock_contract.functions.exists.assert_called_once()
    
    def test_exists_false(self):
        """Test checking if entry exists (false case)"""
        # Mock _find_slot_by_path to return None (entry not found)
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        # Mock getEntry to return entries that don't match
        def mock_get_entry(slot):
            return (0, '0xother', b'other.txt', b'', 0, False, 0, '0x0000000000000000000000000000000000000000')
        
        self.mock_contract.functions.getEntry.side_effect = lambda slot: Mock(call=Mock(return_value=mock_get_entry(slot)))
        
        result = self.manager.exists('0xuser', 'nonexistent.txt')
        
        self.assertFalse(result)
        # Should not call exists if slot is not found
        self.mock_contract.functions.exists.assert_not_called()
    
    def test_get_entry_paginated_success(self):
        """Test getting entry with pagination"""
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0]
        # Mock getEntry to return entry with matching name
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'', 1234567890, True, 100, '0x0000000000000000000000000000000000000000'
        )
        
        # Mock the paginated getEntry call - need to mock __getitem__ properly
        mock_paginated_result = (
            0, '0xuser', b'test.txt', b'Hello', 1234567890, True, 100, '0x0000000000000000000000000000000000000000'
        )
        mock_func_selector = Mock()
        mock_func_selector.return_value.call.return_value = mock_paginated_result
        self.mock_contract.functions.__getitem__ = Mock(return_value=mock_func_selector)
        
        result = self.manager.get_entry_paginated('0xuser', 'test.txt', 0, 5, any_owner=False)
        
        self.assertIsNotNone(result)
        self.assertEqual(result[3], b'Hello')  # body at index 3
        
        # Verify the correct function was called
        self.mock_contract.functions.__getitem__.assert_called_with('getEntry(uint256,uint256,uint256)')
    
    def test_get_entries_paginated_success(self):
        """Test getting entries with pagination"""
        mock_slots = [3, 4, 5]
        mock_func_selector = Mock()
        mock_func_selector.return_value.call.return_value = mock_slots
        self.mock_contract.functions.__getitem__ = Mock(return_value=mock_func_selector)
        
        result = self.manager.get_entries_paginated(2, 3)
        
        self.assertEqual(result, [3, 4, 5])
        self.mock_contract.functions.__getitem__.assert_called_with('getEntries(uint256,uint256)')
    
    def test_get_entries_paginated_failure(self):
        """Test getting entries with pagination when contract call fails"""
        mock_func_selector = Mock()
        mock_func_selector.return_value.call.side_effect = Exception("Call failed")
        self.mock_contract.functions.__getitem__ = Mock(return_value=mock_func_selector)
        
        result = self.manager.get_entries_paginated(0, 10)
        
        self.assertEqual(result, [])
    
    def test_get_entry_count_success(self):
        """Test getting entry count"""
        self.mock_contract.functions.getEntryCount.return_value.call.return_value = 42
        
        result = self.manager.get_entry_count()
        
        self.assertEqual(result, 42)
        self.mock_contract.functions.getEntryCount.assert_called_once()
    
    def test_get_entry_count_failure(self):
        """Test getting entry count when contract call fails"""
        self.mock_contract.functions.getEntryCount.return_value.call.side_effect = Exception("Call failed")
        
        result = self.manager.get_entry_count()
        
        self.assertEqual(result, 0)
    
    def test_get_file_size_success(self):
        """Test getting file size"""
        # Mock _find_slot_by_path to return a slot
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'', 1234567890, True, 100, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.getFileSize.return_value.call.return_value = 1024
        
        result = self.manager.get_file_size('0xuser', 'test.txt', any_owner=False)
        
        self.assertEqual(result, 1024)
    
    def test_get_file_size_not_found(self):
        """Test getting file size when file not found"""
        # Mock _find_slot_by_path to return None
        self.mock_contract.functions.getEntries.return_value.call.return_value = []
        
        result = self.manager.get_file_size('0xuser', 'nonexistent.txt')
        
        self.assertEqual(result, 0)


if __name__ == '__main__':
    unittest.main()
