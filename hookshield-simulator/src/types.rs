pub struct SwapEvent{
    pub pool_id: u64,
    pub block_number: u64,
    pub sqrtpricex96before: u128,
    pub sqrtpricex96after: u128,
    pub amount_in: u128,
    pub zero_for_one: bool, 
    pub timestamp: u64,
}
pub struct VolatilityEvent{
    pub lastsqrtpricex96: u128,
    pub emwavolatility: u128,
    pub lastupdateblock: u64,
}
pub struct SimulationResult{
    pub statticfeelprevenue: u128,
    pub hookshieldlprevenue: u128,
    pub staticfeetotalvolume: u128,
    pub hookshieldtotalvolume: u128,
}