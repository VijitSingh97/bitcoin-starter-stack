import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "reference"))
import node_status

node_status.RPC_URL = os.environ['RPC_URL']
node_status.BITCOIN_DIR = os.environ['DATA_DIR']
node_status.serve(node_status.app, host='127.0.0.1', port=int(os.environ['PORT']))
