"""
Unit tests for RPCManager
"""
import unittest
from unittest.mock import Mock, patch, MagicMock
import os
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
    
    @patch('fuse_eth_fs.rpc_manager.Web3')
    def test_add_rpc_failure(self, mock_web3):
        """Test handling of failed RPC connection"""
        mock_w3_instance = Mock()
        mock_w3_instance.is_connected.return_value = False
        mock_web3.return_value = mock_w3_instance
        
        manager = RPCManager()
        chain_id = manager.add_rpc('http://bad-rpc.com')
        
        self.assertIsNone(chain_id)
    
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


if __name__ == '__main__':
    unittest.main()
