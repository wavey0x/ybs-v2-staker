import brownie
from brownie import Contract
import pytest

def test_operation(
    chain, accounts, token, gov, vault, ybs, 
    reward_distributor, strategy, user, utils, amount, RELATIVE_APPROX, deposit_rewards
):
    token.approve(vault.address, amount, {"from": user})
    WEEK = 60 * 60 * 24 * 7
    threshold = strategy.thresholdTimeUntilWeekEnd()
    trigger = strategy.harvestTrigger(0)
    if trigger:
        strategy.harvest({'from': gov})

    week_end = int(chain.time() / WEEK + 1) * WEEK
    time_until_week_end = week_end - chain.time()
    threshold_start = week_end - threshold
    if time_until_week_end > threshold_start:
        chain.sleep(time_until_week_end - threshold_start + 1)
        chain.mine()
    
    strategy.setCreditThreshold(100e18, {'from':gov})

    amount = strategy.creditThreshold() + 1
    vault.deposit(amount, {"from": user})
    assert strategy.harvestTrigger(0)
    strategy.harvest({'from': gov})
    assert not strategy.harvestTrigger(0)
    vault.deposit(1e18, {"from": user})
    assert not strategy.harvestTrigger(0)