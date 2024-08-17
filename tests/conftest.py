import pytest
import brownie
from brownie import Contract, ZERO_ADDRESS, interface, config, chain


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
    token_address = "0xFCc5c47bE19d06BF83eB04298b026F81069ff65b"  # this should be the address of the ERC-20 used by the strategy/vault (yCRV)
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
    yield Contract("0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F")  # crvUSD v3 vault


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    vault = Contract("0x27B5739e22ad9033bcBf192059122d163b60349D")
    # for i in range(0,20):
    #     s = vault.withdrawalQueue(i)
    #     if s == ZERO_ADDRESS:
    #         break
    #     vault.updateStrategyDebtRatio(s, 0, {'from': gov})
    #     s = Contract(s, owner=gov)
    #     s.harvest()
    yield vault


@pytest.fixture
def registry(gov, reward_token, token):
    registry = Contract("0x262be1d31d0754399d8d5dc63B99c22146E9f738")
    deployment = registry.deployments(token)
    if deployment["yearnBoostedStaker"] == ZERO_ADDRESS:
        tx = registry.createNewDeployment(token, 4, 0, reward_token, {"from": gov})
    yield registry


@pytest.fixture
def ybs(registry, interface, token):
    deployment = registry.deployments(token)
    ybs = interface.IYearnBoostedStaker(deployment["yearnBoostedStaker"])
    yield ybs


@pytest.fixture
def reward_distributor(registry, interface, token):
    deployment = registry.deployments(token)
    reward_distributor = interface.IRewardDistributor(deployment["rewardDistributor"])
    yield reward_distributor


@pytest.fixture
def utils(registry, interface, token):
    deployment = registry.deployments(token)
    utils = interface.IYBSUtilities(deployment["utilities"])
    yield utils


@pytest.fixture
def swapper(gov, reward_token, token, ybs, Swapper):
    token_in = "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E"  # crvUSD
    token_out = token
    token_out_pool1 = "0xD533a949740bb3306d119CC777fa900bA034cd52"
    pool1 = "0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14"
    pool2 = "0x99f5acc8ec2da2bc0771c32814eff52b712de1e5"
    swapper = gov.deploy(Swapper, token_in, token_out, pool1, token_out_pool1, pool2)
    yield swapper

@pytest.fixture
def swapper_v3(gov, reward_token, token, ybs, SwapperV3):
    token_in = '0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E' # crvUSD
    token_out = token
    token_out_pool1 = '0xD533a949740bb3306d119CC777fa900bA034cd52'
    pool1 = '0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14'
    pool2 = '0x99f5acc8ec2da2bc0771c32814eff52b712de1e5'
    swapper = gov.deploy(
        SwapperV3, 
        token_in, 
        token_out,
        pool1,
        token_out_pool1,
        pool2
    )
    yield swapper

@pytest.fixture
def swapper_v2(gov, reward_token, token, ybs, SwapperV2):
    token_in = "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E"  # crvUSD
    token_out = token
    token_out_pool1 = "0xD533a949740bb3306d119CC777fa900bA034cd52"
    pool1 = "0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14"
    swapper = gov.deploy(SwapperV2, token_in, token_out, pool1, token_out_pool1)
    yield swapper


@pytest.fixture
def old_strategy(vault):
    old_strategy = Contract(vault.withdrawalQueue(0))
    yield old_strategy


@pytest.fixture
def strategy(
    strategist,
    keeper,
    vault,
    Strategy,
    gov,
    ybs,
    reward_distributor,
    swapper,
    old_strategy,
    token,
    registry,
    swapper_v3,
):
    # deploy!
    strategy = strategist.deploy(Strategy, vault, ybs, reward_distributor, swapper_v3)
    strategy.setKeeper(keeper)

    # check and print starting boost of strategy
    utils = Contract(registry.deployments(token)["utilities"])
    print(
        "Current active boost:", utils.getUserActiveBoostMultiplier(old_strategy) / 1e18
    )

    # realistically, we'll migrate first before we do anything else
    vault.migrateStrategy(old_strategy, strategy, {"from": gov})

    # make sure it's empty
    assert token.balanceOf(old_strategy) == 0 == old_strategy.estimatedTotalAssets()

    # make gov an approved staker
    with brownie.reverts("!approvedStaker"):
        strategy.manualStakeAsMaxWeighted(95e16, {"from": gov})
    ybs.setWeightedStaker(strategy, True, {"from": gov})

    # approve new strategy as a locker on proxy
    proxy = Contract("0x78eDcb307AC1d1F8F5Fd070B377A6e69C8dcFC34")
    proxy.approveLocker(strategy, True, {"from": gov})

    # do the manual boost setup, 95% max boosted
    strategy.manualStakeAsMaxWeighted(95e16, {"from": gov})
    chain.mine()
    chain.sleep(1)
    print(
        "Current new strategy active boost:",
        utils.getUserActiveBoostMultiplier(strategy) / 1e18,
    )
    print(
        "Current new strategy projected boost:",
        utils.getUserProjectedBoostMultiplier(strategy) / 1e18,
    )
    assert strategy.balanceOfWant() <= 1
    assert strategy.estimatedTotalAssets() > 0

    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5


# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass

@pytest.fixture
def crvusd_dummy_vault(reward_token, gov):
    factory = Contract('0x444045c5c13c246e117ed36437303cac8e250ab0')
    tx = factory.deploy_new_vault(reward_token.asset(), 'dummy-crvusd', 'dummy-crvusd', '0xb3bd6B2E61753C311EFbCF0111f75D29706D9a41', 0, {'from':gov})
    yield tx.return_value

@pytest.fixture
def crvusd_whale(accounts, token, user, reward_token):
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    amount = 100_000e18
    crvusd = Contract(reward_token.asset())
    reserve = accounts.at("0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635", force=True)
    crvusd.transfer(user, amount, {"from": reserve})
    crvusd.approve(reward_token, 2**256 - 1, {"from": user})
    reward_token.deposit(amount, user, {"from": user})
    yield amount


@pytest.fixture(scope="function")
def deposit_rewards(user, reward_token, token, reward_distributor, crvusd_whale):

    def deposit_rewards(user=user, reward_distributor=reward_distributor, token=token):
        reward_token.approve(reward_distributor, 2**256 - 1, {"from": user})

        # Deposit to rewards
        amt = 5_000 * 10**18
        reward_distributor.depositReward(amt, {"from": user})
        week = reward_distributor.getWeek()

        # make sure we at least have this amount
        assert reward_distributor.weeklyRewardAmount(week) >= amt

    yield deposit_rewards