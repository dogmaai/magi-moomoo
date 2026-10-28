"""Execute real bridge endpoint/helper AST with injected broker/HTTP adapters.
Dependency-free fallback; does not verify Flask routing, auth or SDK imports.
"""
import ast
import logging
import math
import os
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

source=Path(__file__).resolve().parents[1] / 'bridge' / 'moomoo_bridge.py'
tree=ast.parse(source.read_text())
names={'_safe_float','_finite','_real_acc_type','_cash_only_violation','_to_moomoo_code','place_order','health'}
functions=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names]
for n in functions: n.decorator_list=[]
ns=dict(math=math,os=os,time=time,log=logging.getLogger('bridge-test'),RET_OK=0,
        OrderType=SimpleNamespace(NORMAL='LIMIT',MARKET='MARKET'),TrdEnv=SimpleNamespace(REAL='REAL',SIMULATE='SIMULATE'),
        TRD_SIDE_MAP={'BUY':'BUY','SELL':'SELL'},ORDER_TYPE_MAP={'LIMIT':'LIMIT','MARKET':'MARKET'},
        jsonify=lambda value:value,MOOMOO_ACC_ID=42,REAL_BUY_PRICE_BUFFER=.02,
        OPEND_HOST='unused',OPEND_PORT=11111,_SIM_ACC_TYPE_TARGET='STOCK',_trade_unlocked=False,BRIDGE_AUTH_TOKEN='test')
exec(compile(ast.Module(body=functions,type_ignores=[]),str(source),'exec'),ns)

class Frame:
    def __init__(self,rows): self.rows=rows;self.iloc=rows
    def __len__(self): return len(self.rows)
    def iterrows(self): return enumerate(self.rows)

class Broker:
    def __init__(self,acc='CASH',cash=1000,qty=10,fail=False):
        self.acc=acc;self.cash=cash;self.qty=qty;self.fail=fail;self.placed=[];self.lookups=[]
    def get_acc_list(self):
        self.lookups.append('account')
        return (-1,'failed') if self.fail else (0,Frame([dict(acc_id=42,trd_env='REAL',acc_type=self.acc)]))
    def position_list_query(self,**kwargs):
        self.lookups.append('positions')
        return (-1,'failed') if self.fail else (0,Frame([dict(code='US.AAPL',qty=self.qty,can_sell_qty=self.qty,position_side='LONG')]))
    def accinfo_query(self,**kwargs):
        self.lookups.append('cash')
        return (-1,'failed') if self.fail else (0,Frame([dict(us_cash=self.cash,cash=self.cash)]))
    def place_order(self,**kwargs):
        self.placed.append(kwargs)
        return 0,Frame([dict(order_id='1',dealt_avg_price=100,dealt_qty=kwargs['qty'],order_status='FILLED_ALL')])

class GuardTests(unittest.TestCase):
    def setup_bridge(self,real,broker,enabled=True,guard=True):
        ns.update(IS_REAL=real,TRD_ENV='REAL' if real else 'SIMULATE',TRD_ENV_STR='REAL' if real else 'SIMULATE',
                  CASH_ONLY=guard,ALLOW_REAL_ORDERS=enabled,_get_trd_ctx=lambda:broker,_reset_trd_ctx=lambda:None)
    def order(self,side,qty=11):
        body=dict(symbol='AAPL',side=side,qty=qty,price=100,order_type='LIMIT')
        ns['request']=SimpleNamespace(get_json=lambda **kw:body)
        value=ns['place_order']()
        return value if isinstance(value,tuple) else (value,200)
    def test_simulate_short_and_margin_buy(self):
        for side in ['SELL','BUY']:
            with self.subTest(side=side):
                broker=Broker(acc='MARGIN',cash=0,qty=0,fail=True)
                self.setup_bridge(False,broker)
                self.assertEqual(self.order(side)[1],200)
                self.assertEqual(len(broker.placed),1)
                self.assertEqual(broker.lookups,[])
                self.assertIsNone(ns['_cash_only_violation'](None,'US.AAPL',side,11,100,'LIMIT'))
    def test_real_cash_guard_blocks_short_margin_buy_and_wrong_account(self):
        for side,broker in [('SELL',Broker(qty=0)),('SELL',Broker(qty=10)),('BUY',Broker(cash=1000)),('BUY',Broker(acc='MARGIN',cash=1e9))]:
            with self.subTest(side=side,acc=broker.acc):
                self.setup_bridge(True,broker)
                body,status=self.order(side)
                self.assertEqual(status,403)
                self.assertEqual(body['blocked_by'],'cash_only_guard')
                self.assertEqual(broker.placed,[])
    def test_real_valid_cash_orders_pass(self):
        for side in ['SELL','BUY']:
            broker=Broker();self.setup_bridge(True,broker)
            self.assertEqual(self.order(side,qty=5)[1],200)
            self.assertEqual(len(broker.placed),1)
    def test_real_lookup_failure_and_exception_fail_closed(self):
        broker=Broker(fail=True);self.setup_bridge(True,broker)
        self.assertEqual(self.order('BUY')[1],403)
        def fail(): raise RuntimeError('unavailable')
        ns['_get_trd_ctx']=fail
        self.assertEqual(self.order('BUY')[1],403)
        self.assertEqual(broker.placed,[])
    def test_real_enable_gate_independent_of_margin_override(self):
        broker=Broker(acc='MARGIN');self.setup_bridge(True,broker,enabled=False,guard=False)
        self.assertEqual(self.order('SELL')[1],403)
        self.assertEqual(broker.placed,[])
    def test_health_reports_effective_policy(self):
        for real,guard,expected in [(False,True,False),(False,False,False),(True,True,True),(True,False,False)]:
            self.setup_bridge(real,Broker(),guard=guard)
            self.assertIs(ns['health']()['cash_only'],expected)

unittest.main(verbosity=2)
