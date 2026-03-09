"""
RPC Manager for handling multiple Ethereum RPC connections with pool support
"""
import json
import os
import threading
import time
from typing import Dict, List, Optional
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()


class RPCManager:
    """Manages multiple RPC connections per chain ID with round-robin load distribution"""

    def __init__(self):
        self.connections: Dict[int, List[Web3]] = {}
        self.rpc_urls: Dict[int, List[str]] = {}
        self._rr_counters: Dict[int, int] = {}
        self._lock = threading.Lock()
        self._config_file_path = os.environ.get('RPC_CONFIG_FILE', 'rpc_config.json')
        self._config_mtime: Optional[float] = None
        self._watcher_thread: Optional[threading.Thread] = None
        self._stop_watcher = threading.Event()
        self._initialize_connections()
        self._load_config_file()
        self._start_config_watcher()

    def _initialize_connections(self):
        """Initialize RPC connections from environment variables"""
        env_vars = os.environ
        rpc_count = 0

        # Check for single RPC_URL (may be comma-separated)
        if 'RPC_URL' in env_vars:
            urls = [u.strip() for u in env_vars['RPC_URL'].split(',') if u.strip()]
            for url in urls:
                self.add_rpc(url)
            rpc_count += len(urls)

        # Check for numbered RPC URLs (RPC_URL_1, RPC_URL_2, etc.) - may be comma-separated
        i = 1
        while f'RPC_URL_{i}' in env_vars:
            urls = [u.strip() for u in env_vars[f'RPC_URL_{i}'].split(',') if u.strip()]
            for url in urls:
                self.add_rpc(url)
            rpc_count += len(urls)
            i += 1

        # Default to localhost if no RPC URLs are configured
        if rpc_count == 0:
            print("No RPC URLs configured, using default localhost:8545")
            self.add_rpc('http://127.0.0.1:8545')

    def _load_config_file(self):
        """Load RPC configuration from JSON config file if it exists"""
        if not os.path.exists(self._config_file_path):
            return

        try:
            mtime = os.path.getmtime(self._config_file_path)
            with open(self._config_file_path, 'r') as f:
                config = json.load(f)
            self._config_mtime = mtime
            self._apply_config(config)
        except Exception as e:
            print(f"Error loading config file {self._config_file_path}: {e}")

    def _apply_config(self, config: dict):
        """Apply configuration from parsed JSON, adding new connections as needed"""
        chains = config.get('chains', {})
        for chain_id_str, chain_config in chains.items():
            rpcs = chain_config.get('rpcs', [])
            chain_id = int(chain_id_str)

            # Get current URLs for this chain
            current_urls = set(self.rpc_urls.get(chain_id, []))

            for url in rpcs:
                if url not in current_urls:
                    self.add_rpc(url)

    def _start_config_watcher(self):
        """Start a background daemon thread to watch for config file changes"""
        self._watcher_thread = threading.Thread(target=self._watch_config, daemon=True)
        self._watcher_thread.start()

    def _watch_config(self):
        """Poll config file mtime every 5 seconds and reload on change"""
        while not self._stop_watcher.is_set():
            self._stop_watcher.wait(5)
            if self._stop_watcher.is_set():
                break
            self._reload_from_config()

    def _reload_from_config(self):
        """Check if config file changed and reload if so"""
        if not os.path.exists(self._config_file_path):
            return

        try:
            mtime = os.path.getmtime(self._config_file_path)
            if mtime != self._config_mtime:
                print(f"Config file changed, reloading {self._config_file_path}")
                with open(self._config_file_path, 'r') as f:
                    config = json.load(f)
                self._config_mtime = mtime
                self._apply_config(config)
        except Exception as e:
            print(f"Error reloading config file: {e}")

    def stop_watcher(self):
        """Stop the config file watcher thread"""
        self._stop_watcher.set()
        if self._watcher_thread:
            self._watcher_thread.join(timeout=10)

    def add_rpc(self, rpc_url: str) -> Optional[int]:
        """
        Add a new RPC connection and auto-detect chain ID.
        If a connection for the same chain_id already exists, appends to the pool.

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

            with self._lock:
                # Append to existing pool or create new one
                if chain_id not in self.connections:
                    self.connections[chain_id] = []
                    self.rpc_urls[chain_id] = []
                    self._rr_counters[chain_id] = 0

                self.connections[chain_id].append(w3)
                self.rpc_urls[chain_id].append(rpc_url)

            print(f"Connected to chain {chain_id} at {rpc_url} (pool size: {len(self.connections[chain_id])})")
            return chain_id

        except Exception as e:
            print(f"Error connecting to RPC {rpc_url}: {e}")
            return None

    def get_connection(self, chain_id: int) -> Optional[Web3]:
        """Get a Web3 connection for a chain ID via round-robin"""
        with self._lock:
            pool = self.connections.get(chain_id)
            if not pool:
                return None
            idx = self._rr_counters[chain_id] % len(pool)
            self._rr_counters[chain_id] = idx + 1
            return pool[idx]

    def get_all_connections(self, chain_id: int) -> List[Web3]:
        """Get all Web3 instances for a chain"""
        with self._lock:
            return list(self.connections.get(chain_id, []))

    def get_pool_size(self, chain_id: int) -> int:
        """Get number of connections for a chain"""
        with self._lock:
            return len(self.connections.get(chain_id, []))

    def get_all_chain_ids(self) -> list:
        """Get list of all connected chain IDs"""
        return list(self.connections.keys())

    def is_connected(self, chain_id: int) -> bool:
        """Check if connected to a specific chain"""
        return chain_id in self.connections and len(self.connections[chain_id]) > 0
