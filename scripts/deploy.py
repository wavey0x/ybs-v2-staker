from brownie import Strategy, Swapper, accounts, config, Contract, project, web3

def main():
    wavey = accounts.load('wavey3')
    ycrv = '0xFCc5c47bE19d06BF83eB04298b026F81069ff65b'
    # Strategy unwraps from vault
    token_in = '0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E' # crvUSD
    token_out = ycrv
    token_out_pool1 = '0xD533a949740bb3306d119CC777fa900bA034cd52' # CRV
    pool1 = '0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14' # TriCRV
    pool2 = '0x99f5acc8ec2da2bc0771c32814eff52b712de1e5' # CRV/yCRV
    swapper = wavey.deploy(
        Swapper, 
        token_in, 
        token_out,
        pool1,
        token_out_pool1,
        pool2
    )


    vault = '0x27B5739e22ad9033bcBf192059122d163b60349D'
    ybs = '0xE9A115b77A1057C918F997c32663FdcE24FB873f'
    ylockers_registry = Contract('0x262be1d31d0754399d8d5dc63B99c22146E9f738')
    deployment = ylockers_registry.deployments(ycrv)
    assert ybs == deployment['yearnBoostedStaker']
    reward_distributor = deployment['rewardDistributor']
    strategy = wavey.deploy(
        Strategy, 
        vault, 
        ybs, 
        reward_distributor, 
        swapper, 
        1000e18,    # min sell
        60_000e18,   # max sell
        publish_source=True
    )
    keeper = '0x736D7e3c5a6CB2CE3B764300140ABF476F6CFCCF'
    strategy.setKeeper(keeper)
    strategy.setCreditThreshold(20_000e18)
    vault.addStrategy(strategy, 10_000, 0, 2**256 - 1, 1_000, {"from": gov})
    yield strategy
