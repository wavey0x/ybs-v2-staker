import brownie
from brownie import Contract
import pytest


def test_operation(
    chain,
    accounts,
    token,
    gov,
    vault,
    ybs,
    reward_distributor,
    strategy,
    user,
    utils,
    amount,
    RELATIVE_APPROX,
    deposit_rewards,
):
    # do a harvest to get all of our loose vault funds into the strategy (assuming no more profitable harvests left)
    assert vault.strategies(strategy)["debtRatio"] == 10_000
    strategy.harvest({"from": gov})

    # deposit rewards and have user deposit
    deposit_rewards()
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Sleep to the next week to be able to claim rewards
    chain.sleep(60 * 60 * 24 * 7)
    chain.mine()

    # if it's our first week, then push the rewards and sleep again
    if utils.getGlobalActiveBoostMultiplier() == 0:
        reward_distributor.pushRewards(utils.getWeek() - 1, {"from": gov})
        chain.sleep(60 * 60 * 24 * 7)
        chain.mine()
        assert utils.getGlobalActiveBoostMultiplier() > 0

    # now our strategy should have some claimable rewards
    assert reward_distributor.getClaimable(strategy) > 0

    # reduce debt on our strategy
    vault.updateStrategyDebtRatio(strategy, 5_000, {"from": gov})
    tx = strategy.harvest()

    # check how much we should be selling on each swap
    print("Amount to sell on each swap max:", strategy.swapThresholds()["max"] / 1e18)
    remaining = Contract(strategy.rewardTokenUnderlying()).balanceOf(strategy) / 1e18
    print("Amount of rewards in strategy after one swap:", remaining)
    print("Remaining split 6 ways:", remaining / 6)

    # check if we're minting or swapping
    try:
        minted = tx.events["Mint"]["value"]
        assert (
            tx.events["Mint"]["minter"] == "0x78ada385b15D89a9B845D2Cac0698663F0c69e3C"
        )
        print("🏦 Just minted", minted / 1e18, "yCRV\n")
    except:
        print("🔄 We're swapping for yCRV")
        # there will be two sets of these events, the first belonging to the crvUSD => CRV swap
        swapped = tx.events["TokenExchange"][1]["tokens_sold"]
        received = tx.events["TokenExchange"][1]["tokens_bought"]
        print("🤑 Just swapped", swapped / 1e18, "CRV for", received / 1e18, "yCRV\n")
    assert (
        vault.totalAssets() * 0.51
        > strategy.estimatedTotalAssets()
        > vault.totalAssets() * 0.49
    )

    # put it back up to 100%
    vault.updateStrategyDebtRatio(strategy, 10_000, {"from": gov})
    tx = strategy.harvest()
    try:
        minted = tx.events["Mint"]["value"]
        assert (
            tx.events["Mint"]["minter"] == "0x78ada385b15D89a9B845D2Cac0698663F0c69e3C"
        )
        print("🏦 Just minted", minted / 1e18, "yCRV\n")
    except:
        print("🔄 We're swapping for yCRV")
        # there will be two sets of these events, the first belonging to the crvUSD => CRV swap
        swapped = tx.events["TokenExchange"][1]["tokens_sold"]
        received = tx.events["TokenExchange"][1]["tokens_bought"]
        print("🤑 Just swapped", swapped / 1e18, "CRV for", received / 1e18, "yCRV\n")

    # have a whale swap in a 500k yCRV
    whale = accounts.at(
        "0x71E47a4429d35827e0312AA13162197C23287546", force=True
    )  # threshold multisig
    pool = Contract("0x99f5aCc8EC2Da2BC0771c32814EFF52b712de1E5")
    token.approve(pool, 2**256 - 1, {"from": whale})
    pool.exchange(1, 0, 500_000e18, 0, {"from": whale})

    # now we should swap instead of minting
    tx = strategy.harvest()
    try:
        minted = tx.events["Mint"]["value"]
        assert (
            tx.events["Mint"]["minter"] == "0x78ada385b15D89a9B845D2Cac0698663F0c69e3C"
        )
        print("🏦 Just minted", minted / 1e18, "yCRV\n")
    except:
        print("🔄 We're swapping for yCRV")
        # there will be two sets of these events, the first belonging to the crvUSD => CRV swap
        swapped = tx.events["TokenExchange"][1]["tokens_sold"]
        received = tx.events["TokenExchange"][1]["tokens_bought"]
        print("🤑 Just swapped", swapped / 1e18, "CRV for", received / 1e18, "yCRV\n")

    # vault will have profit from our harvest sitting in it
    assert (
        pytest.approx(
            strategy.estimatedTotalAssets() + tx.events["Harvested"]["profit"],
            rel=RELATIVE_APPROX,
        )
        == vault.totalAssets()
    )

    # withdrawal
    vault.withdraw({"from": user})
    assert token.balanceOf(user) > user_balance_before


def test_emergency_exit(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
        == vault.totalAssets()
    )

    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < amount


def test_sweep(gov, vault, strategy, token, user, amount, weth, weth_amount):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts():
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts():
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    before_balance = weth.balanceOf(gov)
    weth.transfer(strategy, weth_amount, {"from": user})
    assert weth.address != strategy.want()
    assert weth.balanceOf(user) == 0
    strategy.sweep(weth, {"from": gov})
    assert weth.balanceOf(gov) == weth_amount + before_balance


def test_triggers(
    chain,
    accounts,
    token,
    gov,
    vault,
    ybs,
    reward_distributor,
    strategy,
    user,
    utils,
    amount,
    RELATIVE_APPROX,
    deposit_rewards,
):
    # do a harvest to get all of our loose vault funds into the strategy (assuming no more profitable harvests left)
    assert vault.strategies(strategy)["debtRatio"] == 10_000
    strategy.harvest({"from": gov})

    # deposit rewards and have user deposit
    deposit_rewards()
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest trigger should be false
    assert not strategy.harvestTrigger(0)

    # sleep 2 hours, should be true to claim before end of epoch
    chain.sleep(60 * 60 * 2)
    chain.mine()
    assert strategy.harvestTrigger(0)

    # Sleep to the next week to be able to claim rewards (adjust this based on remaining days in week when testing)
    chain.sleep(60 * 60 * 24)
    chain.mine()

    # if it's our first week, then push the rewards and sleep again
    if utils.getGlobalActiveBoostMultiplier() == 0:
        reward_distributor.pushRewards(utils.getWeek() - 1, {"from": gov})
        chain.sleep(60 * 60 * 24 * 7)
        chain.mine()
        assert utils.getGlobalActiveBoostMultiplier() > 0

    # now our strategy should have some claimable rewards
    assert reward_distributor.getClaimable(strategy) > 0

    # should be true w/ claimable rewards
    assert strategy.harvestTrigger(0)

    # harvest to reset
    strategy.harvest()

    # harvest trigger should be false
    assert not strategy.harvestTrigger(0)

    # sleep 23 hours, should be true again
    chain.sleep(60 * 60 * 23)
    chain.mine()
    assert strategy.harvestTrigger(0)

    # harvest to reset
    strategy.harvest()

    # harvest trigger should be false
    assert not strategy.harvestTrigger(0)

    # sleep 23 hours, should be true again
    chain.sleep(60 * 60 * 23)
    chain.mine()
    assert strategy.harvestTrigger(0)

    # harvest to reset
    strategy.harvest()

    # harvest trigger should be false
    assert not strategy.harvestTrigger(0)
