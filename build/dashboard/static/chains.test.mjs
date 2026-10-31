import {test} from 'node:test';
import assert from 'node:assert/strict';
import {powerView,powerRequest,controlView} from './chains.js';
import {genericNodeView,normalizeNode} from './nodes.js';
import {overviewLayout,previewDepth,GRID} from './tower.js';

const active={configured:true,supported:true,active:true};
test('deactivation requires the exact confirmation and inactive nodes can reactivate',()=>{
  for(const word of ['', 'Deactivate', 'deactivate ', 'yes']) assert.throws(()=>powerRequest(active,word));
  assert.deepEqual(powerRequest(active,'deactivate'),{active:false,confirmation:'deactivate'});
  assert.deepEqual(powerRequest({...active,active:false}),{active:true,confirmation:''});
  assert.equal(powerView(active).button,'Deactivate node');
  assert.equal(powerView({...active,active:false}).button,'Activate node');
  assert.equal(powerView({...active,supported:false}).disabled,true);
  assert.equal(powerView({...active,configured:false}).disabled,true);
});
test('a queued state change remains pending until the host confirms its outcome',()=>{
  const status={id:'a'.repeat(32),node:'litecoin',active:false,state:'pending'};
  assert.equal(controlView({control_available:true,status}).pending,true);
  assert.equal(controlView({control_available:true,status:{...status,state:'applied'}}).pending,false);
  assert.equal(controlView({control_pending:true,status:{...status,id:'bad'}}).pending,true);
  assert.equal(controlView({status:{...status,state:'invented'}}).status,null);
});
test('new chain panels distinguish unavailable data from real zero values',()=>{
  for(const id of ['tari','litecoin','dogecoin','bitcoincash','zcash']) assert.equal(normalizeNode(id),id);
  const view=genericNodeView({enabled:true,available:true,height:100,target_height:200,sync_percent:50,connections_available:false,pruned_available:false,mempool_txs_available:false},'Tari');
  assert.equal(view.blocks,'100 / 200');
  assert.equal(view.progress,50);
  assert.equal(view.connections,'—');
  assert.equal(view.badge,'Pruning unknown');
  assert.equal(view.mempool,'—');
  assert.equal(genericNodeView({enabled:true,available:true,mempool_txs:0,mempool_txs_available:true},'Litecoin').mempool,'0 tx');
});
test('the bouquet fits its canvas and staggers node heights instead of lining them up',()=>{
  for(const width of [320,768,1440,2400]) for(const count of [3,4,5,6,7]) {
    const layout=overviewLayout(width,count,900);
    assert.equal(layout.positions.length,count);
    assert.ok(new Set(layout.anchors).size>1);
    const half=GRID*layout.tw*1.12/2;
    assert.ok(layout.positions.every(x=>x-half>=0 && x+half<=layout.contentWidth));
    for(const y of layout.anchors) assert.ok(previewDepth(900,y,layout.tw)*layout.tw*0.5+y>=900);
  }
});
