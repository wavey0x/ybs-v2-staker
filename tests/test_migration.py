# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!

import pytest


def test_migration(
    chain,
    token,
    vault,
    strategy,
    amount,
    Strategy,
    strategist,
    gov,
    user,
    RELATIVE_APPROX,
    reward_distributor,
    swapper,
    ybs,
    swapper_v2,
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() > amount

    # migrate to a new strategy
    new_strategy = strategist.deploy(
        Strategy, vault, ybs, reward_distributor, swapper_v2
    )
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    assert new_strategy.estimatedTotalAssets() >= amount
