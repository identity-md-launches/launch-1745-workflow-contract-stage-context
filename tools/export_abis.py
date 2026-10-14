#!/usr/bin/env python3
"""Export the reviewed launch ABIs from a completed `forge build`. No network or extra packages."""

import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    target = root / "docs" / "abi"
    target.mkdir(parents=True, exist_ok=True)
    for contract in ("RektToken", "RektJackpotHook", "RektSwapRouter"):
        source = root / "out" / f"{contract}.sol" / f"{contract}.json"
        artifact = json.loads(source.read_text())
        if artifact["bytecode"].get("linkReferences"):
            raise ValueError(f"{contract} has unresolved library links")
        destination = target / f"{contract}.json"
        destination.write_text(json.dumps(artifact["abi"], indent=2) + "\n")
        print(destination.relative_to(root))


if __name__ == "__main__":
    main()
