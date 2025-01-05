<div align="center">
  <img src="https://i.imgur.com/WKU5Chn.png" width="200" />
</div>

## Serpent Router 🐍⛽✨
A modular and gas-efficient router that facilitates token and ether swaps through multiple protocols via swappers. Designed for DEX aggregators to perform multi-route swaps.

* 🛠️ - Still in making
* ✔ - Finished (Untested)
```ml
src
├─ Serpent ✔ — "Serpent contract interface"
├─ WrapperFactory ✔ — "Allows deployment of new wrappers for protocols using Uniswap V2 & V3 Router interfaces to be used in Serpent"
└─ interfaces
   └─ ISerpent ✔ — "Interface of Serpent contract"
└─ wrappers
   └─ V2Wrapper ✔ — "Acts as a wrapper for routers of protocols using UniswapV2Router interfaces to be used in Serpent"
   └─ V3Wrapper ✔ — "Acts as a wrapper for routers of protocols using SwapRouter (Uniswap V3) interfaces to be used in Serpent"
```
