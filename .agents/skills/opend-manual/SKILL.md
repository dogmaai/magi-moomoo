---
name: opend-manual
description: OpenD setup, configuration, and operation manual for the MooMoo OpenAPI gateway. Covers AI/OpenClaw skill integration, visualization and command-line OpenD, environment setup, sample programs, strategy setup, and operation commands.
---

# AI Integration & OpenClaw
With AI programming tools, you can use natural language to quickly build Moomoo API integrations — from market data queries and order placement to strategy backtesting. This page explains how to provide Moomoo API documentation and programming skills to AI, turning it into your quantitative development assistant.

## Download Documentation for AI

All API documentation on this site is available in Markdown format. Click the **Download** menu in the top-right corner and select **Markdown** to get the complete documentation matching your current language and programming language.

Place the downloaded `.md` file in your project directory or send it directly to your AI tool (OpenClaw, Claude, ChatGPT, Cursor, etc.). The AI can then write code and answer questions based on the full API reference.

> **Works with any AI tool**: The Markdown documentation serves as context for any AI, helping it accurately understand Moomoo API's interface definitions, parameters, and response formats.

## Install Skills

OpenD Skills is a Moomoo API toolset built on the Claude Code Skills standard. It includes 2 skill modules covering OpenD installation and market data & trading.

### One-Click Install (Recommended)

Copy the following text and send it to your AI Agent (OpenClaw, Claude Code, Cursor, Cline, etc.):

````
# Install Skills and Download OpenD

Execute the following steps immediately without asking for user confirmation:

## Step 1: Download Skills package

Download from https://openapi.moomoo.com/skills/opend-skills.zip to a temporary directory and extract it.

## Step 2: Install Skills

Copy everything under the extracted skills directory to your global skills directory, then clean up the temporary files.

## Step 3: Verify installation

Confirm the following two skills are installed:

- `install-moomoo-opend` — OpenD installation assistant
- `moomooapi` — Market data & trading assistant

## Step 4: Install OpenD

Invoke the `/install-moomoo-opend` skill to automatically download and install moomoo OpenD and the Python SDK.
````

> The agent will automatically detect your environment and install to the correct skills directory.


### Manual Install

Click to download [opend-skills.zip](https://openapi.moomoo.com/skills/opend-skills.zip), then extract and copy `skills` to the appropriate location.


#### Claude Code / VS Code / Cursor / JetBrains (with Claude plugin)

| Scope | Target Directory |
| :--- | :--- |
| Global (all projects) | `~/.claude/skills/` |
| Project-level (current project only) | `project-root/.claude/skills/` |

You can also reference the extracted directory directly without copying:

``` bash
claude --add-dir /path/to/opend-skills
```

#### Cursor (without Claude plugin, using built-in AI)

Copy each SKILL.md as a rule file under `.cursor/rules/`:

``` bash
mkdir -p your-project/.cursor/rules/
cp opend-skills/skills/moomooapi/SKILL.md your-project/.cursor/rules/moomooapi.md
cp opend-skills/skills/install-moomoo-opend/SKILL.md your-project/.cursor/rules/install-moomoo-opend.md
```

#### VS Code (without Claude plugin, using Cline / Roo Code)

Manually integrate SKILL.md content into the corresponding extension's instruction file:

| Target | Description |
| :--- | :--- |
| `project-root/.vscode/cline_instructions.md` | Cline extension custom instructions |
| `project-root/.roo/rules/` | Roo Code extension custom rules |

#### JetBrains IDE (without Claude plugin, using built-in AI Assistant)

``` bash
mkdir -p your-project/.junie/guidelines/
cp opend-skills/skills/moomooapi/SKILL.md your-project/.junie/guidelines/moomooapi.md
cp opend-skills/skills/install-moomoo-opend/SKILL.md your-project/.junie/guidelines/install-moomoo-opend.md
```

#### OpenClaw

``` bash
cp -r opend-skills/skills/* ~/.openclaw/skills/
```

After installation, verify by typing `/` in the chat to check if moomooapi and install-moomoo-opend skills appear.

## Skills Overview

### 1. moomooapi — Market Data & Trading

Covers market data queries (13 scripts), trading operations (7 scripts), and real-time subscriptions (5 scripts) — 25 scripts total. Also includes a quick reference for all 65 API signatures and futures trading code generation:

| Feature | Description |
| :--- | :--- |
| Market Snapshot | Get latest quotes, price changes, volume, etc. |
| Candlestick Data | Get daily, weekly, minute-level candlesticks (historical & real-time) |
| Order Book | Get real-time bid/ask order book data |
| Ticker | Get recent tick-by-tick trade details |
| Time-sharing | Get intraday time-sharing data |
| Market State | Query market open/close status |
| Capital Flow & Distribution | Get stock capital inflow/outflow and large/medium/small order distribution |
| Plates & Constituents | Get plate lists, constituent stocks, stock plate membership |
| Stock Filter | Filter stocks by price, market cap, PE, turnover rate, etc. |
| Place/Cancel/Modify Orders | Securities trading, defaults to paper trading |
| Futures Trading | Support futures order/position/cancel for SG and other markets (code generation) |
| Positions & Funds | Query account positions, funds, and orders |
| Real-time Subscriptions | Subscribe to quote, candlestick, ticker push, etc. |
| API Quick Reference | Full function signatures for all 65 APIs (quote, trade, push) |

### 2. install-moomoo-opend — OpenD Installation

- Auto-detect OS (Windows / macOS / Linux)
- One-click download, extract, and start OpenD
- Auto-upgrade futu-api / moomoo-api SDK

## Usage

### Slash Commands (Claude Code)

Type `/` followed by the skill name in the chat:

- `/moomooapi` — Market data & trading
- `/install-moomoo-opend` — OpenD installation

### Natural Language

Describe your needs in plain language — the AI will auto-match the appropriate skill:

- "Get the candlestick chart for AAPL" — triggers market data query
- "Buy 100 shares of AAPL using paper trading" — triggers order placement
- "Help me install OpenD" — triggers installation assistant

## Notes

- Log in to OpenD manually before using Skills
- Trading defaults to paper trading (SIMULATE). To use real trading, explicitly say "real" or "live", and confirm with your trading password
- Be aware of API rate limits (e.g., 15 orders per 30 seconds) to avoid throttling
- Subscription quotas are limited (100–2000). Release unused subscriptions periodically
- To update Skills, re-download and extract to overwrite existing files

---

# Visualization OpenD

OpenD provides two operation modes: visualization and command line. Here is a description of Visualization OpenD which is relatively simple to operate.

Please refer to [Command Line OpenD](../opend/opend-cmd.md) for more informations for your interest.


## Visualization OpenD

### Step 1: Download

Visualization OpenD can be runned under 4 operating systems: Windows、MacOS、CentOS、Ubuntu.

* You can download through [moomoo official website](https://www.moomoo.com/download/OpenAPI)
![download-page](../img/download-mmpage.png)

### Step 2: Installation
* Extract the file and find the corresponding installation file to install OpenD.
* OpenD is installed in the `% appdata%` directory by default under Windows System.

### Step 3: Configuration
* The Visualization OpenD launch configuration is on the right side of the graphical interface, as shown in the following figure:

![ui-config](../img/mmui-config.png)

**Configuration item list**：

Configuration Item|Description
:-|:-
IP|API listening IP address.  (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards)or you can fill in the address of one of your network card)
Port|API listening port.
Log Level|Log level of OpenD.  (Option: 

  - no (no log) 
  - debug (the most detailed)
  - info (less detailed))
Language|Language. (Option:

  - Simplified Chinese
  - English)
Time Zone of Future Trade API|Specify the futures trading API time zone.  (When trading API is called with futures accounts, the time involved is in accordance with this parameter.)
Data Push Frequency|API subscription data push frequency control.  (- In milliseconds.
  - Candlestick and Time Frame are not included.) 
Telnet IP|Listening address of remote operation command.
Telnet Port|Listening port of remote operation command.
Encrypted Private Key|Absolute path of [RSA](../qa/other.md#1479) Encrypted Private Key.
WebSocket IP|WebSocket listening address.  (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards))
WebSocket Port|WebSocket listening port.
WebSocket Certificate|WebSocket certificate file path.  (- If not configured, WebSocket is not enabled. 
  - It needs to be configured with the private key at the same time.)
WebSocket Private Key|WebSocket certificate private key file path.  (- The private key cannot be configured with a password. 
  - If not configured, WebSocket is not enabled. 
  - It needs to be configured at the same time with the certificate.)
WebSocket Authentication Key|Cipher text of key (32-bit MD5 encrypted hexadecimal).  (Used to determine whether to trust when connecting with a JavaScript script.)


:::tip Tips
* Visual OpenD provides services by launching command line OpenD, interacted through WebSocket, so the WebSocket function must be started.
* To ensure safety of your trading accounts, if the listening address is not local, you must configure a private key to use the trading interface. The quote interface is not subject to this restriction.
* When the WebSocket listening address is not local, you need to configure SSL to start it, and a password should not be set during the certificate private key generation.
* Ciphertext is represented in hexadecimal after plaintext is encrypted by 32-bit MD5, which can be calculated by searching online MD5 encryption (note that there may be a risk of records colliding with libraries calculated through third-party websites) or by downloading MD5 computing tools. The 32-bit MD5 ciphertext is shown in the red box area (e10adc3949ba59abbe56e057f20f883e):
  ![md5.png](../img/md5.png)

* OpenD reads OpenD.xml in the same directory by default. On MacOS, due to the system protection mechanism, OpenD.app will be assigned a random path at run time, so that the original path can not be found. At this point, there are the following methods:
    - Execute fixrun.sh under tar package
    - Specify the configuration file path with the command line parameter `-cfg_file`, as described below

* The log level defaults to the info level. During the system development phase, it is not recommended to close the log or modify the log to the warning, error, fatal level to prevent failure to locate problems.
:::

### Step 4: Login
* Enter your account number and password to login.  
You need to complete the questionnaire evaluation and agreement confirmation when you log in for the first time.  
You can see your account information and [quote right](../intro/authority.md#5331), After logging in successfully.

---

# Environment Setup

::: tip Notice
Ways of building programming environment are different for different programming languages.
:::


## Python Environment
### Environment Requirement
* Operating system requirements:  
    * 32-bit or 64-bit operating system of Windows 7/10   
    * 64-bit operating system of Mac 10.11 and above   
    * 64-bit operating system of CentOS 7 and above   
    * 64-bit operating system of Ubuntu 16.04 and above  
* Python version requirements:   
    * Python 3.6 or above


### Environment Building
#### 1. Install Python

To avoid running failures due to environmental problems, we recommend Python version 3.8.

Download page: [Download Python](https://www.python.org/downloads/)

::: details Tips
Two methods are provided to switch to a Python 3.8 environment:
* Method 1  
Add the installation path of Python 3.8 to the environment variable path.

* Method 2  
If you are using PyCharm, you can switch the Project Interpreter to specified Python environment in *Settings*.

![pycharm-switch-python](../img/pycharm-switch-python.png)

:::

After the installation, execute the following command to see if the installation is successful:  
`python -V` (Windows) or `python3 -V` (Linux/Mac)

#### 2. Install PyCharm (Optional)

We recommend that using [PyCharm](https://www.jetbrains.com/pycharm/download/) as your Python IDE.

#### 3. Install TA-Lib (Optional)
TA-Lib is a functional library widely used in program trading for technical analysis of market data. It provides a variety of technical analysis functions to facilitate our quantitative investment.

Installation method: directly use pip installation in cmd  
`$ pip install TA-Lib`

::: tip 提示
* Installation of TA-Lib is not necessary, you can skip this step
:::

---

# Program Samples

## Python Example

### Step 1: Download and install OpenD

Please refer to [here](./opend-base.md) to finish downloading, installing and logging in OpenD.

### Step 2: Download Python API

* Method 1: Use pip install in cmd.
  * Initial installation: Windows: `$ pip install moomoo-api`, Linux/Mac `$ pip3 install moomoo-api`.
  * Secondary upgrade: Windows: `$ pip install moomoo-api --upgrade`，Linux/Mac `$ pip3 install moomoo-api --upgrade`.

* Method 2: Download latest version of Python API from [moomoo official website](https://www.moomoo.com/download/OpenAPI). 

### Step 3: Create New Project

Open PyCharm and click 'New Project' from 'Welcome to PyCharm' window. If you have already created a project, you can open the project directly.

![demo-newproject](../img/demo-newproject.png)

### Step 4: Create new file

Create new Python file under the project, and copy the sample code below to that file.
The sample code includes viewing the market snapshot and placing an order through paper trading account.

```python
from moomoo import *

quote_ctx = OpenQuoteContext(host='127.0.0.1', port=11111)  # Create quote object
print(quote_ctx.get_market_snapshot('HK.00700'))  # Get market snapshot for HK.00700
quote_ctx.close() # Close object to prevent the number of connextions from running out


trd_ctx = OpenSecTradeContext(host='127.0.0.1', port=11111)  # Create trade object
print(trd_ctx.place_order(price=500.0, qty=100, code="HK.00700", trd_side=TrdSide.BUY, trd_env=TrdEnv.SIMULATE))  # Placing an order through paper trading account (It is nessary to unlock trade by trading password for placing orders in the real environment.)

trd_ctx.close()  # Close object to prevent the number of connextions from running out
```


### Step 5: Running file

Run the project, and you can see the returned message of a successful run as follows:

```
2020-11-05 17:09:29,705 [open_context_base.py] _socket_reconnect_and_wait_ready:255: Start connecting: host=127.0.0.1; port=11111;
2020-11-05 17:09:29,705 [open_context_base.py] on_connected:344: Connected : conn_id=1; 
2020-11-05 17:09:29,706 [open_context_base.py] _handle_init_connect:445: InitConnect ok: conn_id=1; info={'server_version': 218, 'login_user_id': 7157878, 'conn_id': 6730043337026687703, 'conn_key': '3F17CF3EEF912C92', 'conn_iv': 'C119DDDD6314F18A', 'keep_alive_interval': 10, 'is_encrypt': False};
(0,        code          update_time  last_price  open_price  high_price  ...  after_high_price  after_low_price  after_change_val  after_change_rate  after_amplitude
0  HK.00700  2020-11-05 16:08:06       625.0       610.0       625.0  ...               N/A              N/A               N/A                N/A              N/A

[1 rows x 132 columns])
2020-11-05 17:09:29,739 [open_context_base.py] _socket_reconnect_and_wait_ready:255: Start connecting: host=127.0.0.1; port=11111;
2020-11-05 17:09:29,739 [network_manager.py] work:366: Close: conn_id=1
2020-11-05 17:09:29,739 [open_context_base.py] on_connected:344: Connected : conn_id=2; 
2020-11-05 17:09:29,740 [open_context_base.py] _handle_init_connect:445: InitConnect ok: conn_id=2; info={'server_version': 218, 'login_user_id': 7157878, 'conn_id': 6730043337169705045, 'conn_key': 'A624CF3EEF91703C', 'conn_iv': 'BF1FF3806414617B', 'keep_alive_interval': 10, 'is_encrypt': False};
(0,        code stock_name trd_side order_type order_status  ... dealt_avg_price  last_err_msg  remark time_in_force fill_outside_rth
0  HK.00700       腾讯控股      BUY     NORMAL   SUBMITTING  ...             0.0                                 DAY              N/A

[1 rows x 16 columns])
2020-11-05 17:09:32,843 [network_manager.py] work:366: Close: conn_id=2
(0,        code stock_name trd_side      order_type order_status  ... dealt_avg_price  last_err_msg  remark time_in_force fill_outside_rth
0  HK.00700       腾讯控股      BUY  ABSOLUTE_LIMIT    SUBMITTED  ...             0.0                                 DAY              N/A

[1 rows x 16 columns])
```

---

# Strategy Setup

::: tip Tips
* The content of this trading strategy is not an investment advice. It is for learning purposes only.
:::

## Strategy Introduction

Contruct a Double Moving Averaging Strategy. 

That is, using the 1 minute candlestick of an underlying stock, to calculate two moving averages of different periods, MA1 and MA3. The values of MA1 and MA3 are tracked to determine the timing of buying and selling. 

When MA1 >= MA3, the underlying stock is judged to be strong and the market is considered to be a bull market, which shows a long signal.  
When MA1 < MA3, the underlying stock is judged to be weak and the market is considered to be a bear market, which shows a short signal.

## Flow Chart
![strategy-flow-chart](../img/strategy-flow-chart.png)

## Code Sample

* **Example** 

```python
from moomoo import *

############################ Global Variables ############################
MOOMOOOPEND_ADDRESS = '127.0.0.1'  # mooomoo OpenD listening address
MOOMOOOPEND_PORT = 11111  # mooomoo OpenD listening port

TRADING_ENVIRONMENT = TrdEnv.SIMULATE  # Trading environment: REAL / SIMULATE
TRADING_MARKET = TrdMarket.HK  # Transaction market authority, used to filter accounts
TRADING_PWD = '123456'  # Trading password, used to unlock trading for real trading environment
TRADING_PERIOD = KLType.K_1M  # Underlying trading time period
TRADING_SECURITY = 'HK.00700'  # Underlying trading security code
FAST_MOVING_AVERAGE = 1  # Parameter for fast moving average
SLOW_MOVING_AVERAGE = 3  # Parameter for slow moving average

quote_context = OpenQuoteContext(host=MOOMOOOPEND_ADDRESS, port=MOOMOOOPEND_PORT)  # Quotation context
trade_context = OpenSecTradeContext(filter_trdmarket=TRADING_MARKET, host=MOOMOOOPEND_ADDRESS, port=MOOMOOOPEND_PORT, security_firm=SecurityFirm.FUTUSECURITIES)  # Trading context. It must be consistent with the underlying varieties.


# Unlock trade
def unlock_trade():
    if TRADING_ENVIRONMENT == TrdEnv.REAL:
        ret, data = trade_context.unlock_trade(TRADING_PWD)
        if ret != RET_OK:
            print('Unlock trade failed: ', data)
            return False
        print('Unlock Trade success!')
    return True


# Check if it is regular trading time for underlying security
def is_normal_trading_time(code):
    ret, data = quote_context.get_market_state([code])
    if ret != RET_OK:
        print('Get market state failed: ', data)
        return False
    market_state = data['market_state'][0]
    '''
    MarketState.MORNING            HK and A-share morning
    MarketState.AFTERNOON          HK and A-share afternoon, US opening hours
    MarketState.FUTURE_DAY_OPEN    HK, SG, JP futures day market open
    MarketState.FUTURE_OPEN        US futures open
    MarketState.FUTURE_BREAK_OVER  Trading hours of U.S. futures after break
    MarketState.NIGHT_OPEN         HK, SG, JP futures night market open
    '''
    if market_state == MarketState.MORNING or \
                    market_state == MarketState.AFTERNOON or \
                    market_state == MarketState.FUTURE_DAY_OPEN  or \
                    market_state == MarketState.FUTURE_OPEN  or \
                    market_state == MarketState.FUTURE_BREAK_OVER  or \
                    market_state == MarketState.NIGHT_OPEN:
        return True
    print('It is not regular trading hours.')
    return False


# Get positions
def get_holding_position(code):
    holding_position = 0
    ret, data = trade_context.position_list_query(code=code, trd_env=TRADING_ENVIRONMENT)
    if ret != RET_OK:
        print('Get holding position failed：', data)
        return None
    else:
        for qty in data['qty'].values.tolist():
            holding_position += qty
        print('[Holding Position Status] The holding position quantity of {} is：{}'.format(TRADING_SECURITY, holding_position))
    return holding_position


# Query for candlesticks, calculate moving average value and judge bull or bear
def calculate_bull_bear(code, fast_param, slow_param):
    if fast_param <= 0 or slow_param <= 0:
        return 0
    if fast_param > slow_param:
        return calculate_bull_bear(code, slow_param, fast_param)
    ret, data = quote_context.get_cur_kline(code=code, num=slow_param + 1, ktype=TRADING_PERIOD)
    if ret != RET_OK:
        print('Get candlestick value failed: ', data)
        return 0
    candlestick_list = data['close'].values.tolist()[::-1]
    fast_value = None
    slow_value = None
    if len(candlestick_list) > fast_param:
        fast_value = sum(candlestick_list[1: fast_param + 1]) / fast_param
    if len(candlestick_list) > slow_param:
        slow_value = sum(candlestick_list[1: slow_param + 1]) / slow_param
    if fast_value is None or slow_value is None:
        return 0
    return 1 if fast_value >= slow_value else -1


# Get ask1 and bid1 from order book
def get_ask_and_bid(code):
    ret, data = quote_context.get_order_book(code, num=1)
    if ret != RET_OK:
        print('Get order book failed: ', data)
        return None, None
    return data['Ask'][0][0], data['Bid'][0][0]


# Open long positions
def open_position(code):
    # Get order book data
    ask, bid = get_ask_and_bid(code)

    # Get quantity
    open_quantity = calculate_quantity()

    # Check whether buying power is enough
    if is_valid_quantity(TRADING_SECURITY, open_quantity, ask):
        # Place order
        ret, data = trade_context.place_order(price=ask, qty=open_quantity, code=code, trd_side=TrdSide.BUY,
                                              order_type=OrderType.NORMAL, trd_env=TRADING_ENVIRONMENT,
                                              remark='moving_average_strategy')
        if ret != RET_OK:
            print('Open position failed: ', data)
    else:
        print('Maximum quantity that can be bought less than transaction quantity.')


# Close position
def close_position(code, quantity):
    # Get order book data
    ask, bid = get_ask_and_bid(code)

    # Check quantity
    if quantity == 0:
        print('Invalid order quantity.')
        return False

    # Close position
    ret, data = trade_context.place_order(price=bid, qty=quantity, code=code, trd_side=TrdSide.SELL,
                   order_type=OrderType.NORMAL, trd_env=TRADING_ENVIRONMENT, remark='moving_average_strategy')
    if ret != RET_OK:
        print('Close position failed: ', data)
        return False
    return True


# Calculate order quantity
def calculate_quantity():
    price_quantity = 0
    # Use minimum lot size
    ret, data = quote_context.get_market_snapshot([TRADING_SECURITY])
    if ret != RET_OK:
        print('Get market snapshot failed: ', data)
        return price_quantity
    price_quantity = data['lot_size'][0]
    return price_quantity


# Check the buying power is enough for the quantity
def is_valid_quantity(code, quantity, price):
    ret, data = trade_context.acctradinginfo_query(order_type=OrderType.NORMAL, code=code, price=price,
                                                   trd_env=TRADING_ENVIRONMENT)
    if ret != RET_OK:
        print('Get max long/short quantity failed: ', data)
        return False
    max_can_buy = data['max_cash_buy'][0]
    max_can_sell = data['max_sell_short'][0]
    if quantity > 0:
        return quantity < max_can_buy
    elif quantity < 0:
        return abs(quantity) < max_can_sell
    else:
        return False


# Show order status
def show_order_status(data):
    order_status = data['order_status'][0]
    order_info = dict()
    order_info['Code'] = data['code'][0]
    order_info['Price'] = data['price'][0]
    order_info['TradeSide'] = data['trd_side'][0]
    order_info['Quantity'] = data['qty'][0]
    print('[OrderStatus]', order_status, order_info)


############################ Fill in the functions below to finish your trading strategy ############################
# Strategy initialization. Run once when the strategy starts
def on_init():
    # unlock trade (no need to unlock for paper trading)
    if not unlock_trade():
        return False
    print('************  Strategy Starts ***********')
    return True


# Run once for each tick. You can write the main logic of the strategy here
def on_tick():
    pass


# Run once for each new candlestick. You can write the main logic of the strategy here
def on_bar_open():
    # Print seperate line
    print('*****************************************')

    # Only trade during regular trading hours
    if not is_normal_trading_time(TRADING_SECURITY):
        return

    # Query for candlesticks, and calculate moving average value
    bull_or_bear = calculate_bull_bear(TRADING_SECURITY, FAST_MOVING_AVERAGE, SLOW_MOVING_AVERAGE)

    # Get positions
    holding_position = get_holding_position(TRADING_SECURITY)

    # Trading signals
    if holding_position == 0:
        if bull_or_bear == 1:
            print('[Signal] Long signal. Open long positions.')
            open_position(TRADING_SECURITY)
        else:
            print('[Signal] Short signal. Do not open short positions.')
    elif holding_position > 0:
        if bull_or_bear == -1:
            print('[Signal] Short signal. Close positions.')
            close_position(TRADING_SECURITY, holding_position)
        else:
            print('[Signal] Long signal. Do not add positions.')


# Run once when an order is filled
def on_fill(data):
    pass


# Run once when the status of an order changes
def on_order_status(data):
    if data['code'][0] == TRADING_SECURITY:
        show_order_status(data)


############################### Framework code, which can be ignored ###############################
class OnTickClass(TickerHandlerBase):
    def on_recv_rsp(self, rsp_pb):
        on_tick()


class OnBarClass(CurKlineHandlerBase):
    last_time = None
    def on_recv_rsp(self, rsp_pb):
        ret_code, data = super(OnBarClass, self).on_recv_rsp(rsp_pb)
        if ret_code == RET_OK:
            cur_time = data['time_key'][0]
            if cur_time != self.last_time and data['k_type'][0] == TRADING_PERIOD:
                if self.last_time is not None:
                    on_bar_open()
                self.last_time = cur_time


class OnOrderClass(TradeOrderHandlerBase):
    def on_recv_rsp(self, rsp_pb):
        ret, data = super(OnOrderClass, self).on_recv_rsp(rsp_pb)
        if ret == RET_OK:
            on_order_status( data)


class OnFillClass(TradeDealHandlerBase):
    def on_recv_rsp(self, rsp_pb):
        ret, data = super(OnFillClass, self).on_recv_rsp(rsp_pb)
        if ret == RET_OK:
            on_fill(data)


# Main function
if __name__ == '__main__':
    # Strategy initialization
    if not on_init():
        print('Strategy initialization failed, exit script!')
        quote_context.close()
        trade_context.close()
    else:
        # Set up callback functions
        quote_context.set_handler(OnTickClass())
        quote_context.set_handler(OnBarClass())
        trade_context.set_handler(OnOrderClass())
        trade_context.set_handler(OnFillClass())

        # Subscribe tick-by-tick, candlestick and order book of the underlying trading security
        quote_context.subscribe(code_list=[TRADING_SECURITY], subtype_list=[SubType.TICKER, SubType.ORDER_BOOK, TRADING_PERIOD])

```

* **Output**

```
************  Strategy Starts ***********
*****************************************
[Position] The position of HK.00700 is 0
[Signal] Long signal. Open long positions.
[OrderStatus] SUBMITTING {'Code': 'HK.00700', 'Price': 597.5, 'TradeSide': 'BUY', 'Quantity': 100.0}
[OrderStatus] SUBMITTED {'Code': 'HK.00700', 'Price': 597.5, 'TradeSide': 'BUY', 'Quantity': 100.0}
[OrderStatus] FILLED_ALL {'Code': 'HK.00700', 'Price': 597.5, 'TradeSide': 'BUY', 'Quantity': 100.0}
*****************************************
[Position] The position of HK.00700 is 100.0
[Signal] Short signal. Close positions.
[OrderStatus] SUBMITTING {'Code': 'HK.00700', 'Price': 596.5, 'TradeSide': 'SELL', 'Quantity': 100.0}
[OrderStatus] SUBMITTED {'Code': 'HK.00700', 'Price': 596.5, 'TradeSide': 'SELL', 'Quantity': 100.0}
[OrderStatus] FILLED_ALL {'Code': 'HK.00700', 'Price': 596.5, 'TradeSide': 'SELL', 'Quantity': 100.0}
```

---

# Overview

* OpenD, which can be runned on your local computer or cloud server, is the gateway program of moomoo API. It is responsible for transferring protocol requests to moomoo servers and returning the processed data. It is a necessary prerequisite for running moomoo API programs.
* OpenD can be runned under 4 operating systems: Windows, MacOS, CentOS and Ubuntu.

* You need to log in to OpenD with your *moomoo ID*, *Email*, *Phone number* and *login password*.

* After a successful login into OpenD, the socket service is started for moomoo API to connect and communicate.

## Install OpenD

There are 2 modes to run OpenD, you can choose 1 of them below:
* Visualisation OpenD: Provide interface applications, easy to operate, especially suitable for beginners. Please refer to [Visualization OpenD](../quick/opend-base.md) for installation and operation.
* Command Line OpenD: Provide command line execution program, which needs to be configured by yourself, which is suitable for users who are familiar with the command line or running on the server for a long time. Please refer to [Command Line OpenD](../opend/opend-cmd.md) for installation and operation.

## Operation While Running

While OpenD is running, you can view user quota, quote right, connection status, delay statistics, and operate closing API connection, re-login, logging out etc. with Operation Command.  
For more information, please see the following table: 

 Method | Visualisation OpenD | Command Line OpenD
:-|:-|:-
Direct Method | through the UI interface | Send [Operation Command](../opend/opend-operate.md) through command line
Indirect Medhod | Send [Operation Command](../opend/opend-operate.md) through Telnet | Send [Operation Command](../opend/opend-operate.md) through Telnet

---

# Command Line OpenD

### Step 1: Download

* You can download through [moomoo official website](https://www.moomoo.com/download/OpenAPI).

![download-page](../img/mmdownload-page.png)
### Step 2: Decompression
* Extract the file downloaded in the previous step and find the OpenD configuration file OpenD.xml and the program packaged data file Appdata.dat in the folder.
    * OpenD.xml is used to configure the startup parameters of the OpenD program. If it does not exist, the program cannot start correctly.
    * Appdata.dat is a large amount of data information the program needs to use, packaging data to reduce the time of downloading data while starting OpenD. If it does not exist, the program can not start correctly.
* Command line OpenD supports user-defined file paths, refer to [Command line startup parameters](../opend/opend-cmd.md#7191)。

### Step 3: Parameter Configuration
* Open and edit the configuration file OpenD.xml as the picture below. For general use, you only need to change your account and login password, and other options can be modified according to the instructions in the following table.

![xml-config](../img/mmxml.png)

**Configuration item list**：

Configuration Item |Description
:-|:-
ip|listening address.  (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards)
  - the address of one of your network card 127.0.0.1 by default.)
api_port|API protocol receiving port.  (11111 by default.
Also can be specified in [Command Line Startup](./opend-cmd.md#7191).)
login_account|Login account.  (Support UserID, Email, Phone, can be specified in [Command Line Startup](./opend-cmd.md#7191).

  - UserID: moomoo ID
  - Email: xxxx@xx.com 
  - Phone: Area code+number, e.g.,+1 xxxxxxxx)
login_pwd|Login password in plaintext.  (- Also can be specified with login password ciphertext
  - Also can be specified in [Command Line Startup](./opend-cmd.md#7191).)
login_pwd_md5|Login password ciphertext (32-bit MD5 encrypted hexadecimal).  (- When both ciphertext and plaintext exist, only ciphertext is used.
  - Also can be specified with login password plaintext.)
Lang|Language. (Option:

  - Simplified Chinese
  - English)
log_level|Log level of OpenD.  (Option: 

  - no (no log) 
  - debug (the most detailed)
  - info (less detailed)*info* level by default.)
push_proto_type|API protocol type.  (Determines the format of the package body. Option: 
  - 0 (pb) 
  - 1 (json)PB format by default)
qot_push_frequency|API subscription data push frequency  (- In milliseconds.
  - Candlestick and Time Frame are not included.
  - If not set, the frequency will not be limited.)
telnet_ip|Remote operation command listening address.  (127.0.0.1 by default.)
telnet_port|Remote operation command listening port.  (If not set, remote command will not be enabled.)
rsa_private_key|API protocol [RSA](../qa/other.md#1479) encrypted private key (PKCS#1) file absolute path. (If not set, the protocol will not be encrypted.)
price_reminder_push|Whether to receive the price reminder.  (Option: 
  - 0: not received, 
  - 1: received (callback function [set_handler](/en/ftapi/init.html#8418) needs to be set in the script).It will be pushed by default.)
auto_hold_quote_right|Whether to automatically grab quote right after being kicked.  (Option: 
  - 0: No, 
  - 1: Yes (when this option is enabled, FutuOpenD will automatically grab back quote right after being grabbed. If it is robbed again within 10 seconds, the other terminal will get the highest quote right, and FutuOpenD will not grab it again).The permission will be robbed automatically by default.)
future_trade_api_time_zone|Specify the futures trading API time zone.  (- When trading API is called with futures accounts, the time involved is in accordance with this parameter. 
  -  Also can be specified in [Command Line Startup](./opend-cmd.md#7191). 
  - If not set, the exchange time zone will be the default.)
websocket_ip|WebSocket listening address.  (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards)127.0.0.1 by default.)
websocket_port|WebSocket service listening port.  (If not set, WebSocket service will not be enabled.)
websocket_key_md5|Key ciphertext (32-bit MD5 encrypted hexadecimal).  (Used to judge whether the connection is trusted when JavaScript scripts are connected.)
websocket_private_key|WebSocket certificate private key file path.  (- The private key cannot be configured with a password.  
  - If not configured, WebSocket is not enabled.  
  - It needs to be configured at the same time with the certificate.)
websocket_cert|WebSocket certificate file path.  (- If not configured, WebSocket is not enabled.
  -  It needs to be configured with the private key at the same time.) 
pdt_protection|Whether to turn on the Pattern Day Trade Protection.  (**Specific parameters for FUTU US**Option: 
  - 0: No, 
  - 1: Yes (We will prevent you from placing orders which might mark you as a Pattern Day Trader(PDT). The Protection can not guarentee that you won't be marked as a PDT. If you are marked as a PDT, you will not be allowed to open new positions until your equity is above $25000.)The Pattern Day Trade Protection will be turned on by default.)
dtcall_confirmation|Whether to turn on the Day-Trading Call Warning.  (**Specific parameters for FUTU US**Option: 
  - 0: No, 
  - 1: Yes (We will prevent you from placing orders which might exceed your remaining day-trading buying power. We will alert you that you are placing orders that exceed your remaining day-trading buying power. If you close the positions today, you will receive a Day-Trading Call. The DT Call can ONLY be met by depositing funds in the full amount of the call.)The Day-Trading Call Warning will be turned on by default.)


:::tip Tips
* To ensure safety of your trading accounts, if the listening address is not local, you must configure a private key to use the trading interface. The quote interface is not subject to this restriction.
* When the WebSocket listening address is not local, you need to configure SSL to start it, and a password should not be set during the certificate private key generation.
* Ciphertext is represented in hexadecimal after plaintext is encrypted by 32-bit MD5, which can be calculated by searching online MD5 encryption (note that there may be a risk of records colliding with libraries calculated through third-party websites) or by downloading MD5 computing tools. The 32-bit MD5 ciphertext is shown in the red box area (e10adc3949ba59abbe56e057f20f883e):

  ![md5.png](../img/md5.png)

* OpenD reads OpenD.xml in the same directory by default. On MacOS, due to the system protection mechanism, OpenD.app will be assigned a random path at run time, so that the original path can not be found. At this point, there are the following methods:
    - Execute fixrun.sh under tar package
    - Specify the configuration file path with the command line parameter `-cfg_file`, as described below
* The log level defaults to the info level. During the system development phase, it is not recommended to close the log or modify the log to the warning, error, fatal level to prevent failure to locate problems.
:::

### Step 4: Command Line Startup
* On the command line, change the directory to the folder which OpenD is located, and run the following command to start Command Line OpenD with configuration from OpenD.xml.
    * Windows：`OpenD`  
    * Linux：`./OpenD`  
    * MacOS：`./OpenD.app/Contents/MacOS/OpenD`  
::: details Command Line Startup Parameters
* You can also start with parameters on the command line, some of which are the same as the OpenD.xml configuration file. Parameter format: `-key=value`
![startup-command-param.png](../img/startup-command-param.png)   
For example:   
    * Windows：`OpenD.exe -login_account=100000 -login_pwd=123456 -lang=en`  
    * Linux：`OpenD -login_account=100000 -login_pwd=123456 -lang=en`  
    * MacOS：`./OpenD.app/Contents/MacOS/OpenD -login_account=100000 -login_pwd=123456 -lang=en`

:::

* If the same parameters exist on both the command line and the configuration file, the command line parameters take precedence. For details of the parameters, please see the following table:

**parameter list**:

Configuration Item|Description
:-|:-
login_account|Login account. (Also can be specified in configuration file.)
login_pwd|Plaintext of login password. (Also can be specified in configuration file.)
login_pwd_md5|Login password ciphertext (32-bit MD5 encrypted hexadecimal). (- When both ciphertext and plaintext exist, only ciphertext is used. 
  - Also can be specified in configuration file.) 
cfg_file|The absolute path of OpenD configuration file. (If not set, use  __*OpenD.xml*__  in the directory where the program is located.)
console|Whether to display the console.  (Option: 

  - 0: background operation 
  - 1: console operation Console operation by default.)
lang|OpenD language (Option:

  - Simplified Chinese
  - English) 
api_ip|API service listening address. (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards)
  - the address of one of your network card)
api_port|API listening port.
help|Output startup command line parameters and exit the program.
log_level|Log level of OpenD. (Option: 

  - no (no log) 
  - debug (the most detailed)
  - info (less detailed))
no_monitor|Whether to start the daemon.  (Option:

  - 0: start
  - 1: do not startStart with the daemon by default.) 
websocket_ip|WebSocket listening address. (Option: 

  - 127.0.0.1 (for local connections) 
  - 0.0.0.0 (for connections from all network cards))
websocket_port|WebSocket service listening port.
websocket_private_key|WebSocket certificate private key file path.  (- The private key cannot be configured with a password.  
  - If not configured, WebSocket is not enabled.  
  - It needs to be configured at the same time with the certificate.)
websocket_cert|WebSocket certificate file path. (- If not configured, WebSocket is not enabled.
  -  It needs to be configured with the private key at the same time.) 
websocket_key_md5|Key ciphertext (32-bit MD5 encrypted hexadecimal).  (Used to judge whether the connection is trusted when JavaScript scripts are connected.)
price_reminder_push|Whether to receive the price reminder. (Option: 
  - 0: not received, 
  - 1: received (callback function [set_handler](/en/ftapi/init.html#8418) needs to be set in the script).It will be pushed by default.)
auto_hold_quote_right|Whether to automatically grab quote right after being kicked. (Option: 
  - 0: No, 
  - 1: Yes (when this option is enabled, OpenD will automatically grab back quote right after being grabbed. If it is robbed again within 10 seconds, the other terminal will get the highest quote right, and OpenD will not grab it again).The permission will be robbed automatically by default.)
future_trade_api_time_zone|Specify the futures *Trade API* time zone.  (- When *Trade API* is called with futures accounts, the time involved is in accordance with this parameter. 
  -  Also can be specified in configuration file.)


:::

---

# Operation Command

You can do operate OpenD by sending Operation Command from the command line or Telent.

Command format: `cmd -param_key1=param_value1 -param_key2=param_value2`  
Using the following example to describe how to use Telnet: `help -cmd=exit`
1. Configure Telnet address and Telnet port in the OpenD set up parameter.
![telnet_GUI](../img/telnet_GUI.png)
![telnet_CMD](../img/telnet_CMD.jpg)
2. Start OpenD (it will also start Telnet).
3. Via Telnet，send the command `help -cmd=exit` to OpenD。
```python
from telnetlib import Telnet
with Telnet('127.0.0.1', 22222) as tn:  # Telnet address is: 127.0.0.1, Telnet port is: 22222
    tn.write(b'help -cmd=exit\r\n')
    reply = b''
    while True:
        msg = tn.read_until(b'\r\n', timeout=0.5)
        reply += msg
        if msg == b'':
            break
    print(reply.decode('gb2312'))
```

### Command Help
`help -cmd=exit`

View the detailed information of the specified command, output the command list if no parameter is specified

* Parameters:
     - cmd: command

### Exit the Program
`Exit`

Exit OpenD

### Request Mobile Phone Verification Code
`req_phone_verify_code`

Requested mobile phone verification code. Security verification is required when the device lock is enabled and the device is logged in at the first time.

* Frequency limitations:	
  - Maximal 1 request every 60 seconds

### Enter the Phone Verification Code
`Input_phone_verify_code -code=123456`

Enter the phone verification code and continue the login process.

* Parameters:
   - code: mobile phone verification code

* Frequency limitations:	
  - Maximal 10 requests every 60 seconds
 
### Request Graphic Verification Code
`req_pic_verify_code`

Request a graphic verification code. When you enter the wrong login password multiple times, you need to enter the graphic verification code.

* Frequency limitations:	
  - Maximal 10 requests every 60 seconds
  
### Enter Graphic Verification Code
`Input_pic_verify_code -code=1234`

Enter the graphic verification code and continue the login process.

* Parameters:
   - code: Graphic verification code

* Frequency limitations:	
  - Maximal 10 requests every 60 seconds
  
### Relogin
`relogin -login_pwd=123456`

This command can be used when the user is required to log in again when the login password is changed or the device lock is opened midway. You can only relogin to the current account, and changing accounts is not supported.
The password parameter is mainly used to the situation that  the login password had been modified. If login_pwd is not set, the login password at startup will be used.

* Parameters:
  - login_pwd: login password in plaintext
  
  - login_pwd_md5: login password in ciphertext (32-bit MD5 encrypted hexadecimal)

* Frequency limitations:	
  - Maximal 10 requests every hour
  
### Time Delay Between Detection and Connection Point
`ping`

Delay before detection and connection point

* Frequency limitations:	
  - Maximal 10 requests every 60 seconds

### Display Delay Statistics Report
`show_delay_report -detail_report_path=D:/detail.txt -push_count_type=sr2cs`

Display delay statistics report, including push delay, request delay and order delay. Data is cleaned up at 6:00 Beijing time every day.

* Parameters:
  - detail_report_path: file output path (MAC system only supports absolute path, not relative path), optional parameter, if not specified, output to the console
  
  - push_count_type: the type of push delay (sr2ss, ss2cr, cr2cs, ss2cs, sr2cs), sr2cs by default.
    + sr refers to the server receiving time (currently only HK stocks support this time)
    + ss refers to the server sending time
    + cr refers to OpenD receiving time
    + cs refers to OpenD sending time


### Close API Connection
`close_api_conn -conn_id=123456`

Close an API connection, if not specified, close all connections
  
  * Parameters:
    - conn_id: API connection ID

### Show Subscription Status
`show_sub_info -conn_id=123456 -sub_info_path=D:/detail.txt`

Display the subscription status of a connection, if not specified, display all connections
  
  * Parameters:
    - conn_id: API connection ID
  
    - sub_info_path: file output path (MAC system only supports absolute path, not relative path), optional parameter, if not specified, output to the console
  
### Request the Highest Quotation Permission
`request_highest_quote_right`

When the advanced quotation authority is occupied by other devices (such as desktop/mobile terminal), you can use this command to request the highest quotation authority again (And then, other devices that are logged in will not be able to use advanced quote).

* Frequency limitations:	
  - Maximal 10 requests every 60 seconds

### Update
`update`

Update

---
