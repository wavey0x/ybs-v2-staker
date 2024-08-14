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
    # Deposit to the vault
    vault.updateStrategyDebtRatio(strategy, 10_000, {"from": gov})
    strategy.harvest({"from": gov})

    deposit_rewards()
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Claim rewards
    chain.sleep(60 * 60 * 24 * 7)
    chain.mine()
    if utils.getGlobalActiveBoostMultiplier() == 0:
        reward_distributor.pushRewards(utils.getWeek() - 1, {"from": gov})
        chain.sleep(60 * 60 * 24 * 7)
        chain.mine()
        assert utils.getGlobalActiveBoostMultiplier() > 0
    assert reward_distributor.getClaimable(strategy) > 0

    vault.updateStrategyDebtRatio(strategy, 5_000, {"from": gov})
    tx = strategy.harvest()
    assert (
        vault.totalAssets() * 0.51
        > strategy.estimatedTotalAssets()
        > vault.totalAssets() * 0.49
    )

    vault.updateStrategyDebtRatio(strategy, 10_000, {"from": gov})
    tx = strategy.harvest()
    assert (
        pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX)
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
    chain, gov, vault, strategy, token, amount, user, weth, weth_amount, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
