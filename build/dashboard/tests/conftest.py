import os
import sys

# node_status.py reads credentials from the environment at import time
os.environ.setdefault("RPC_USER", "testuser")
os.environ.setdefault("RPC_PASSWORD", "testpass")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
