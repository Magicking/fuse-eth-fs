"""
RPC Manager for handling multiple Ethereum RPC connections
"""
import os
from typing import Dict, Optional
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()


class RPCManager:
    """Manages multiple RPC connections and chain IDs"""
    
    def __init__(self):
        self.connections: Dict[int, Web3] = {}
        self.rpc_urls: Dict[int, str] = {}
        self._initialize_connections()
    
    def _initialize_connections(self):
        """Initialize RPC connections from environment variables"""
        # Look for RPC_URL_<number> environment variables
        env_vars = os.environ
        rpc_count = 0
        
        # Check for single RPC_URL
        if 'RPC_URL' in env_vars:
            self.add_rpc(env_vars['RPC_URL'])
            rpc_count += 1
        
        # Check for numbered RPC URLs (RPC_URL_1, RPC_URL_2, etc.)
        i = 1
        while f'RPC_URL_{i}' in env_vars:
            self.add_rpc(env_vars[f'RPC_URL_{i}'])
            i += 1
            rpc_count += 1
        
        # Default to localhost if no RPC URLs are configured
        if rpc_count == 0:
            print("No RPC URLs configured, using default localhost:8545")
            self.add_rpc('http://127.0.0.1:8545')
    
    def add_rpc(self, rpc_url: str) -> Optional[int]:
        """
        Add a new RPC connection and auto-detect chain ID
        
        Args:
            rpc_url: The RPC endpoint URL
            
        Returns:
            The chain ID if connection successful, None otherwise
        """
        try:
            w3 = Web3(Web3.HTTPProvider(rpc_url))
            
            # Check if connection is successful
            if not w3.is_connected():
                print(f"Failed to connect to RPC: {rpc_url}")
                return None
            
            # Get chain ID
            chain_id = w3.eth.chain_id
            
            # Store connection
            self.connections[chain_id] = w3
            self.rpc_urls[chain_id] = rpc_url
            
            print(f"Connected to chain {chain_id} at {rpc_url}")
            return chain_id
            
        except Exception as e:
            print(f"Error connecting to RPC {rpc_url}: {e}")
            return None
    
    def get_connection(self, chain_id: int) -> Optional[Web3]:
        """Get Web3 connection for a specific chain ID"""
        return self.connections.get(chain_id)
    
    def get_all_chain_ids(self) -> list:
        """Get list of all connected chain IDs"""
        return list(self.connections.keys())
    
    def is_connected(self, chain_id: int) -> bool:
        """Check if connected to a specific chain"""
        return chain_id in self.connections
