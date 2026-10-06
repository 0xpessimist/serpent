<div align="center">
  <img src="https://i.imgur.com/WKU5Chn.png" width="200" />
</div>

## Serpent Router 🐍⛽✨
A modular and gas-efficient router that facilitates token and ether swaps through multiple protocols via swappers. Designed for DEX aggregators to perform multi-route swaps.

* 🛠️ - Still in making
* ✔ - Finished
```ml
src
├─ Serpent ✔ — "Serpent DEX Aggregation Router contract"
├─ WrapperFactory ✔ — "Allows deployment of new wrappers for protocols using Uniswap V2 & V3 Router interfaces to be used in Serpent"
├─ interfaces
│  └─ ISerpent ✔ — "Interface of Serpent contract"
├─ libraries
│  └─ PermitLib ✔ — "Native token permit and Permit2 helper"
└─ wrappers
   ├─ BaseWrapper ✔ — "Base for delegatecall-only protocol wrappers"
   ├─ V2Wrapper ✔ — "Acts as a wrapper for routers of protocols using UniswapV2Router interfaces to be used in Serpent"
   ├─ V3Wrapper ✔ — "Acts as a wrapper for routers of protocols using SwapRouter (Uniswap V3) interfaces to be used in Serpent"
   ├─ V3Wrapper02 ✔ — "Wrapper for protocols using Uniswap SwapRouter02"
   └─ SlipstreamWrapper ✔ — "Wrapper for protocols using Aerodrome/Velodrome Slipstream routers"
```
