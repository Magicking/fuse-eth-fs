"""
Unit tests for filesystem path parsing
"""
import unittest


class TestFileSystemPathParsing(unittest.TestCase):
    
    def _parse_path(self, path: str) -> tuple:
        """
        Parse a path into its components (copied from EthFS for testing)
        
        Returns: (chain_id, account_address, relative_path)
        """
        parts = [p for p in path.split('/') if p]
        
        if len(parts) == 0:
            return (None, None, None)
        
        # First level is chain ID
        try:
            chain_id = int(parts[0])
        except ValueError:
            return (None, None, None)
        
        if len(parts) == 1:
            return (chain_id, None, None)
        
        # Second level is account address
        account = parts[1]
        
        if len(parts) == 2:
            return (chain_id, account, None)
        
        # Rest is the relative path
        relative_path = '/'.join(parts[2:])
        return (chain_id, account, relative_path)
    
    def test_parse_root_path(self):
        """Test parsing root path"""
        chain_id, account, rel_path = self._parse_path('/')
        
        self.assertIsNone(chain_id)
        self.assertIsNone(account)
        self.assertIsNone(rel_path)
    
    def test_parse_chain_id_path(self):
        """Test parsing chain ID path"""
        chain_id, account, rel_path = self._parse_path('/1337')
        
        self.assertEqual(chain_id, 1337)
        self.assertIsNone(account)
        self.assertIsNone(rel_path)
    
    def test_parse_account_path(self):
        """Test parsing account path"""
        chain_id, account, rel_path = self._parse_path('/1337/0xabcd1234')
        
        self.assertEqual(chain_id, 1337)
        self.assertEqual(account, '0xabcd1234')
        self.assertIsNone(rel_path)
    
    def test_parse_file_path(self):
        """Test parsing file path"""
        chain_id, account, rel_path = self._parse_path('/1337/0xabcd1234/test.txt')
        
        self.assertEqual(chain_id, 1337)
        self.assertEqual(account, '0xabcd1234')
        self.assertEqual(rel_path, 'test.txt')
    
    def test_parse_nested_path(self):
        """Test parsing nested directory path"""
        chain_id, account, rel_path = self._parse_path('/1337/0xabcd1234/dir1/dir2/file.txt')
        
        self.assertEqual(chain_id, 1337)
        self.assertEqual(account, '0xabcd1234')
        self.assertEqual(rel_path, 'dir1/dir2/file.txt')
    
    def test_parse_invalid_chain_id(self):
        """Test parsing invalid chain ID"""
        chain_id, account, rel_path = self._parse_path('/invalid/0xabcd1234')
        
        self.assertIsNone(chain_id)
        self.assertIsNone(account)
        self.assertIsNone(rel_path)
    
    def test_parse_empty_parts(self):
        """Test parsing with empty parts (trailing slashes)"""
        chain_id, account, rel_path = self._parse_path('/1337/0xabcd1234/')
        
        self.assertEqual(chain_id, 1337)
        self.assertEqual(account, '0xabcd1234')
        self.assertIsNone(rel_path)


if __name__ == '__main__':
    unittest.main()
