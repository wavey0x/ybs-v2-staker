# TODO: Add tests that show proper operation of this strategy through "emergencyExit"
#       Make sure to demonstrate the "worst case losses" as well as the time it takes

from brownie import ZERO_ADDRESS
import pytest


def test_vault_shutdown_can_withdraw(
    chain, token, vault, strategy, user, amount, RELATIVE_APPROX
):
    ## Deposit in Vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) >= amount

    if token.balanceOf(user) > 0:
        token.transfer(ZERO_ADDRESS, token.balanceOf(user), {"from": user})

    # Harvest 1: Send funds through the strategy
    strategy.harvest()
    chain.sleep(3600 * 7)
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= amount

    ## Set Emergency
    vault.setEmergencyShutdown(True, {"from": vault.governance()})

    ## Withdraw (does it work, do you get what you expect)
    vault.withdraw({"from": user})

    assert token.balanceOf(user) >= amount - 2


def test_basic_shutdown(
    chain, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) >= amount

    # Harvest 1: Send funds through the strategy
    strategy.harvest()
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= amount

    ## Earn interest
    chain.sleep(3600 * 24 * 1)  ## Sleep 1 day
    chain.mine(1)

    # Harvest 2: Realize profit
    strategy.harvest()
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    ## Set emergency
    strategy.setEmergencyExit({"from": strategist})

    strategy.harvest()  ## Remove funds from strategy

    assert token.balanceOf(strategy) == 0
    assert token.balanceOf(vault) >= amount  ## The vault has all funds
    ## NOTE: May want to tweak this based on potential loss during migration
