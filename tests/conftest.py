import pytest
from brownie import config
from brownie import Contract, ZERO_ADDRESS


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0xFCc5c47bE19d06BF83eB04298b026F81069ff65b"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x99f5aCc8EC2Da2BC0771c32814EFF52b712de1E5", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amount(user, weth):
    weth_amount = 10 ** weth.decimals()
    user.transfer(weth, weth_amount)
    yield weth_amount

@pytest.fixture
def reward_token():
    yield Contract('0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E') # crvUSD

@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    vault = Contract('0x27B5739e22ad9033bcBf192059122d163b60349D')
    # for i in range(0,20):
    #     s = vault.withdrawalQueue(i)
    #     if s == ZERO_ADDRESS:
    #         break
    #     vault.updateStrategyDebtRatio(s, 0, {'from': gov})
    #     s = Contract(s, owner=gov)
    #     s.harvest()
    yield vault

@pytest.fixture
def ybs(pm, gov, rewards, guardian, management, token, YearnBoostedStaker):
    ybs = gov.deploy(YearnBoostedStaker, token, 4, 0, gov)
    yield ybs

@pytest.fixture
def reward_distributor(gov, reward_token, token, ybs, SingleTokenRewardDistributor):
    reward_distributor = gov.deploy(SingleTokenRewardDistributor, ybs, reward_token)
    yield reward_distributor
    

@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, ybs, reward_distributor):
    strategy = strategist.deploy(Strategy, vault, ybs, reward_distributor)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2**256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5


# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass
