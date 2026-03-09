"""
Unit tests for RPCManager
"""
import json
import os
import tempfile
import time
import unittest
from unittest.mock import Mock, patch, MagicMock
from fuse_eth_fs.rpc_manager import RPCManager


class TestRPCManager(unittest.TestCase):

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_default_rpc_url(self, mock_web3):
        """Test that default localhost RPC is used when no env vars set"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1337
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()

        self.assertEqual(len(manager.get_all_chain_ids()), 1)
        self.assertIn(1337, manager.get_all_chain_ids())
        manager.stop_watcher()

    @patch.dict(os.environ, {'RPC_URL': 'http://test-rpc.com'})
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_single_rpc_url(self, mock_web3):
        """Test single RPC_URL from environment"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()

        self.assertEqual(len(manager.get_all_chain_ids()), 1)
        self.assertIn(1, manager.get_all_chain_ids())
        self.assertEqual(manager.get_pool_size(1), 1)
        manager.stop_watcher()

    @patch.dict(os.environ, {
        'RPC_URL_1': 'http://rpc1.com',
        'RPC_URL_2': 'http://rpc2.com',
        'RPC_URL_3': 'http://rpc3.com'
    })
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_multiple_rpc_urls(self, mock_web3):
        """Test multiple numbered RPC URLs"""
        chain_ids = [1, 137, 56]

        def create_mock(chain_id):
            mock = Mock()
            mock.is_connected.return_value = True
            mock.eth.chain_id = chain_id
            return mock

        mock_web3.side_effect = [create_mock(cid) for cid in chain_ids]

        manager = RPCManager()

        self.assertEqual(len(manager.get_all_chain_ids()), 3)
        for cid in chain_ids:
            self.assertIn(cid, manager.get_all_chain_ids())
        manager.stop_watcher()

    @patch.dict(os.environ, {'RPC_URL_1': 'http://rpc1.com,http://rpc2.com,http://rpc3.com'})
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_comma_separated_urls(self, mock_web3):
        """Test comma-separated URLs create a pool for the same chain"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1337
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()

        self.assertEqual(manager.get_pool_size(1337), 3)
        self.assertEqual(len(manager.get_all_connections(1337)), 3)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_round_robin(self, mock_web3):
        """Test round-robin distribution across pool"""
        mocks = []
        for i in range(3):
            m = Mock()
            m.is_connected.return_value = True
            m.eth.chain_id = 1337
            m.name = f"w3_{i}"
            mocks.append(m)

        mock_web3.side_effect = mocks

        manager = RPCManager()
        # Default adds 1 connection, manually add 2 more
        manager.add_rpc('http://rpc2.com')
        manager.add_rpc('http://rpc3.com')

        # Round-robin should cycle through all 3
        conn1 = manager.get_connection(1337)
        conn2 = manager.get_connection(1337)
        conn3 = manager.get_connection(1337)
        conn4 = manager.get_connection(1337)  # Should wrap around

        self.assertEqual(conn1, mocks[0])
        self.assertEqual(conn2, mocks[1])
        self.assertEqual(conn3, mocks[2])
        self.assertEqual(conn4, mocks[0])
        manager.stop_watcher()

    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_add_rpc_success(self, mock_web3):
        """Test adding RPC connection manually"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 42
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()
        chain_id = manager.add_rpc('http://new-rpc.com')

        self.assertEqual(chain_id, 42)
        self.assertTrue(manager.is_connected(42))
        manager.stop_watcher()

    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_add_rpc_failure(self, mock_web3):
        """Test handling of failed RPC connection"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = False
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()
        chain_id = manager.add_rpc('http://bad-rpc.com')

        self.assertIsNone(chain_id)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_add_rpc_same_chain_appends_to_pool(self, mock_web3):
        """Test that adding RPCs for the same chain appends to pool"""
        mock_w3 = Mock()
        mock_w3.is_connected.return_value = True
        mock_w3.eth.chain_id = 1337
        mock_web3.return_value = mock_w3

        manager = RPCManager()
        self.assertEqual(manager.get_pool_size(1337), 1)

        manager.add_rpc('http://rpc2.com')
        self.assertEqual(manager.get_pool_size(1337), 2)

        manager.add_rpc('http://rpc3.com')
        self.assertEqual(manager.get_pool_size(1337), 3)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_get_connection(self, mock_web3):
        """Test getting Web3 connection by chain ID"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1337
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()
        connection = manager.get_connection(1337)

        self.assertIsNotNone(connection)
        self.assertEqual(connection.eth.chain_id, 1337)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_get_connection_nonexistent_chain(self, mock_web3):
        """Test getting connection for a chain that doesn't exist"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1337
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()
        connection = manager.get_connection(9999)

        self.assertIsNone(connection)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_is_connected(self, mock_web3):
        """Test checking connection status"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = True
        mock_w3_instance.eth.chain_id = 1337
        mock_web3.return_value = mock_w3_instance

        manager = RPCManager()

        self.assertTrue(manager.is_connected(1337))
        self.assertFalse(manager.is_connected(9999))
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_get_all_connections(self, mock_web3):
        """Test getting all connections for a chain"""
        mocks = []
        for _ in range(3):
            m = Mock()
            m.is_connected.return_value = True
            m.eth.chain_id = 1337
            mocks.append(m)
        mock_web3.side_effect = mocks

        manager = RPCManager()
        manager.add_rpc('http://rpc2.com')
        manager.add_rpc('http://rpc3.com')

        all_conns = manager.get_all_connections(1337)
        self.assertEqual(len(all_conns), 3)

        # Should return a copy, not the internal list
        all_conns.append(Mock())
        self.assertEqual(manager.get_pool_size(1337), 3)
        manager.stop_watcher()

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_config_file_loading(self, mock_web3):
        """Test loading configuration from JSON file"""
        mock_w3 = Mock()
        mock_w3.is_connected.return_value = True
        mock_w3.eth.chain_id = 1337
        mock_web3.return_value = mock_w3

        config = {
            "chains": {
                "1337": {
                    "rpcs": ["http://config-rpc1.com", "http://config-rpc2.com"]
                }
            }
        }

        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(config, f)
            config_path = f.name

        try:
            with patch.dict(os.environ, {'RPC_CONFIG_FILE': config_path}, clear=True):
                manager = RPCManager()
                # Default localhost + 2 from config = 3
                self.assertEqual(manager.get_pool_size(1337), 3)
                manager.stop_watcher()
        finally:
            os.unlink(config_path)

    @patch.dict(os.environ, {}, clear=True)
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_config_file_reload(self, mock_web3):
        """Test hot-reload of config file"""
        mock_w3 = Mock()
        mock_w3.is_connected.return_value = True
        mock_w3.eth.chain_id = 1337
        mock_web3.return_value = mock_w3

        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump({"chains": {}}, f)
            config_path = f.name

        try:
            with patch.dict(os.environ, {'RPC_CONFIG_FILE': config_path}, clear=True):
                manager = RPCManager()
                initial_size = manager.get_pool_size(1337)  # 1 (default localhost)

                # Update config file
                time.sleep(0.1)  # Ensure different mtime
                with open(config_path, 'w') as f:
                    json.dump({
                        "chains": {
                            "1337": {"rpcs": ["http://new-rpc.com"]}
                        }
                    }, f)

                # Trigger reload
                manager._reload_from_config()

                self.assertEqual(manager.get_pool_size(1337), initial_size + 1)
                manager.stop_watcher()
        finally:
            os.unlink(config_path)


if __name__ == '__main__':
    unittest.main()
