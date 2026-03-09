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

    def test_single_w3_creates_pool_of_one(self):
        """Test that passing a single Web3 creates a pool of size 1"""
        self.assertEqual(self.manager.pool_size, 1)
        self.assertIs(self.manager.w3, self.mock_w3)
        self.assertIs(self.manager.contract, self.mock_contract)

    def test_list_w3_creates_pool(self):
        """Test that passing a list of Web3 creates a pool"""
        mock_w3_1 = Mock()
        mock_w3_2 = Mock()
        mock_w3_3 = Mock()
        mock_contract_1 = Mock()
        mock_contract_2 = Mock()
        mock_contract_3 = Mock()

        mock_w3_1.eth.contract.return_value = mock_contract_1
        mock_w3_2.eth.contract.return_value = mock_contract_2
        mock_w3_3.eth.contract.return_value = mock_contract_3

        manager = ContractManager(
            [mock_w3_1, mock_w3_2, mock_w3_3],
            '0x1234567890abcdef1234567890abcdef12345678'
        )

        self.assertEqual(manager.pool_size, 3)
        # Primary (write) should be first
        self.assertIs(manager.w3, mock_w3_1)
        self.assertIs(manager.contract, mock_contract_1)

    def test_round_robin_get_contract(self):
        """Test that _get_contract cycles through the pool"""
        mock_w3_1 = Mock()
        mock_w3_2 = Mock()
        mock_contract_1 = Mock()
        mock_contract_2 = Mock()

        mock_w3_1.eth.contract.return_value = mock_contract_1
        mock_w3_2.eth.contract.return_value = mock_contract_2

        manager = ContractManager(
            [mock_w3_1, mock_w3_2],
            '0x1234567890abcdef1234567890abcdef12345678'
        )

        c1 = manager._get_contract()
        c2 = manager._get_contract()
        c3 = manager._get_contract()  # wraps around

        self.assertIs(c1, mock_contract_1)
        self.assertIs(c2, mock_contract_2)
        self.assertIs(c3, mock_contract_1)

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

        self.mock_contract.functions.getEntries.return_value.call.side_effect = [
            [0, 1],
            [0, 1, 2]
        ]
        self.mock_contract.functions.createDirectory.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt

        result = self.manager.create_directory('mydir', '0xuser')

        self.assertTrue(result)
        self.mock_contract.functions.createDirectory.assert_called_once_with(
            b'mydir',
            '0x0000000000000000000000000000000000000000'
        )

    def test_update_file_success(self):
        """Test successful file update"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}

        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'old content', 1234567890, True, 12, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.updateFile.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt

        result = self.manager.update_file('test.txt', b'new content', '0xuser')

        self.assertTrue(result)
        self.mock_contract.functions.updateFile.assert_called_once()
        call_args = self.mock_contract.functions.updateFile.call_args[0]
        self.assertEqual(call_args[1], b'new content')
        self.assertEqual(call_args[2], 0)

    def test_delete_entry_success(self):
        """Test successful entry deletion"""
        mock_tx_hash = '0xabcd'
        mock_receipt = {'status': 1}

        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'content', 1234567890, True, 7, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.deleteEntry.return_value.transact.return_value = mock_tx_hash
        self.mock_w3.eth.wait_for_transaction_receipt.return_value = mock_receipt

        result = self.manager.delete_entry('test.txt', '0xuser')

        self.assertTrue(result)
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

        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = expected_entry

        result = self.manager.get_entry('0xuser', 'test.txt')

        self.assertEqual(result, expected_entry)
        self.mock_contract.functions.getEntry.assert_called()

    def test_get_entry_failure(self):
        """Test getting entry when call fails"""
        self.mock_contract.functions.getEntry.return_value.call.side_effect = Exception("Call failed")

        result = self.manager.get_entry('0xuser', 'test.txt')

        self.assertIsNone(result)

    def test_get_account_paths(self):
        """Test getting all paths for an account"""
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]

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

        self.assertIn('file1.txt', result)
        self.assertIn('file2.txt', result)
        self.assertIn('dir1', result)
        self.mock_contract.functions.getEntries.assert_called_once()

    def test_exists_true(self):
        """Test checking if entry exists (true case)"""
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'content', 1234567890, True, 7, '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.exists.return_value.call.return_value = True

        result = self.manager.exists('0xuser', 'test.txt')

        self.assertTrue(result)
        self.mock_contract.functions.exists.assert_called_once()

    def test_exists_false(self):
        """Test checking if entry exists (false case)"""
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0, 1, 2]
        def mock_get_entry(slot):
            return (0, '0xother', b'other.txt', b'', 0, False, 0, '0x0000000000000000000000000000000000000000')

        self.mock_contract.functions.getEntry.side_effect = lambda slot: Mock(call=Mock(return_value=mock_get_entry(slot)))

        result = self.manager.exists('0xuser', 'nonexistent.txt')

        self.assertFalse(result)
        self.mock_contract.functions.exists.assert_not_called()

    def test_get_entry_count(self):
        """Test getting entry count"""
        self.mock_contract.functions.getEntryCount.return_value.call.return_value = 5

        result = self.manager.get_entry_count()

        self.assertEqual(result, 5)
        self.mock_contract.functions.getEntryCount.assert_called_once()

    def test_get_entry_count_failure(self):
        """Test getting entry count when call fails"""
        self.mock_contract.functions.getEntryCount.return_value.call.side_effect = Exception("Call failed")

        result = self.manager.get_entry_count()

        self.assertEqual(result, 0)

    def test_get_entries_paginated(self):
        """Test getting paginated entries"""
        self.mock_contract.functions.getEntriesPaginated.return_value.call.return_value = [2, 3, 4]

        result = self.manager.get_entries_paginated(2, 3)

        self.assertEqual(result, [2, 3, 4])
        self.mock_contract.functions.getEntriesPaginated.assert_called_once_with(2, 3)

    def test_get_entries_paginated_failure(self):
        """Test getting paginated entries when call fails"""
        self.mock_contract.functions.getEntriesPaginated.return_value.call.side_effect = Exception("Call failed")

        result = self.manager.get_entries_paginated(0, 10)

        self.assertEqual(result, [])

    def test_iter_entries(self):
        """Test iterating over entries in pages"""
        self.mock_contract.functions.getEntryCount.return_value.call.return_value = 5
        self.mock_contract.functions.getEntriesPaginated.return_value.call.side_effect = [
            [0, 1, 2],  # First page
            [3, 4],     # Second page
        ]

        result = list(self.manager.iter_entries(page_size=3))

        self.assertEqual(result, [0, 1, 2, 3, 4])

    def test_iter_entries_empty(self):
        """Test iterating over empty entries"""
        self.mock_contract.functions.getEntryCount.return_value.call.return_value = 0

        result = list(self.manager.iter_entries(page_size=10))

        self.assertEqual(result, [])

    def test_read_file_chunked(self):
        """Test reading a file in chunks"""
        self.mock_contract.functions.getEntries.return_value.call.return_value = [0]
        self.mock_contract.functions.getEntry.return_value.call.return_value = (
            0, '0xuser', b'test.txt', b'Hello World!', 1234567890, True, 12,
            '0x0000000000000000000000000000000000000000'
        )
        self.mock_contract.functions.readFile.return_value.call.side_effect = [
            b'Hello',   # First chunk (5 bytes)
            b' World',  # Second chunk (6 bytes)
            b'!',       # Third chunk (1 byte)
        ]

        chunks = list(self.manager.read_file_chunked('test.txt', chunk_size=5, account='0xuser'))

        self.assertEqual(len(chunks), 3)
        self.assertEqual(b''.join(chunks), b'Hello World!')

    def test_parallel_get_entries(self):
        """Test parallel fetching of multiple entries"""
        entry_0 = (0, '0xuser', b'file1.txt', b'content1', 100, True, 8, '0x' + '0' * 40)
        entry_1 = (0, '0xuser', b'file2.txt', b'content2', 200, True, 8, '0x' + '0' * 40)
        entry_2 = (1, '0xuser', b'dir1', b'', 300, True, 0, '0x' + '0' * 40)

        def mock_get_entry_for_slot(slot):
            mock = Mock()
            if slot == 0:
                mock.call.return_value = entry_0
            elif slot == 1:
                mock.call.return_value = entry_1
            elif slot == 2:
                mock.call.return_value = entry_2
            return mock

        self.mock_contract.functions.getEntry.side_effect = mock_get_entry_for_slot

        results = self.manager.parallel_get_entries([0, 1, 2], max_workers=2)

        self.assertEqual(len(results), 3)
        self.assertEqual(results[0], entry_0)
        self.assertEqual(results[1], entry_1)
        self.assertEqual(results[2], entry_2)

    def test_parallel_get_entries_empty(self):
        """Test parallel fetching with empty slot list"""
        results = self.manager.parallel_get_entries([])
        self.assertEqual(results, {})

    def test_parallel_get_entries_with_errors(self):
        """Test parallel fetching handles individual errors gracefully"""
        entry_0 = (0, '0xuser', b'file1.txt', b'content1', 100, True, 8, '0x' + '0' * 40)

        def mock_get_entry_for_slot(slot):
            mock = Mock()
            if slot == 0:
                mock.call.return_value = entry_0
            elif slot == 1:
                mock.call.side_effect = Exception("RPC error")
            return mock

        self.mock_contract.functions.getEntry.side_effect = mock_get_entry_for_slot

        results = self.manager.parallel_get_entries([0, 1], max_workers=2)

        # Slot 0 should succeed, slot 1 should be skipped
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0], entry_0)

    def test_writes_use_primary_contract(self):
        """Test that write operations use the first (primary) contract"""
        mock_w3_1 = Mock()
        mock_w3_2 = Mock()
        mock_contract_1 = Mock()
        mock_contract_2 = Mock()

        mock_w3_1.eth.contract.return_value = mock_contract_1
        mock_w3_2.eth.contract.return_value = mock_contract_2

        manager = ContractManager(
            [mock_w3_1, mock_w3_2],
            '0x1234567890abcdef1234567890abcdef12345678'
        )

        # Write operations should always use the first contract
        self.assertIs(manager.contract, mock_contract_1)
        self.assertIs(manager.w3, mock_w3_1)


if __name__ == '__main__':
    unittest.main()
