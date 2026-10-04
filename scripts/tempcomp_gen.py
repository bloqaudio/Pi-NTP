#!/usr/bin/env python3
"""
Generate a chrony tempcomp points file from temperature vs frequency data.

Reads plot_data.txt (Time;Frequency;Temperature CSV), fits a quadratic
curve to temperature vs frequency, and outputs a chrony tempcomp lookup
table at 0.5C resolution.

The output file contains:
    temperature_in_millidegrees compensation_in_ppm

The compensation is generated relative to the fitted turnover temperature,
so the driftfile can handle the baseline frequency and tempcomp only needs
to correct the temperature-dependent deviation around that point.
"""

import csv
import sys
import numpy as np


def load_data(filepath: str) -> tuple[np.ndarray, np.ndarray]:
    """Load temperature and frequency data from CSV."""
    temps = []
    freqs = []
    with open(filepath, "r") as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            try:
                temps.append(float(row["Temperature"]))
                freqs.append(float(row["Frequency"]))
            except (ValueError, KeyError):
                continue
    return np.array(temps), np.array(freqs)


def fit_quadratic(
    temps: np.ndarray, freqs: np.ndarray
) -> tuple[np.poly1d, np.ndarray]:
    """Fit a quadratic curve to temperature vs frequency data."""
    coeffs = np.polyfit(temps, freqs, 2)
    poly = np.poly1d(coeffs)
    return poly, coeffs


def generate_tempcomp(
    poly: np.poly1d,
    temp_min: float,
    temp_max: float,
    ref_temp: float,
    step: float = 0.5,
) -> list[tuple[int, float]]:
    """Generate tempcomp table entries.

    Chrony expects compensation points in ppm, not a ppm/degree slope.
    The fitted curve models the frequency error versus temperature. We
    normalize that curve around a reference temperature and negate the
    deviation so chrony applies the opposite correction.
    """
    baseline = float(poly(ref_temp))
    entries = []
    temp = temp_min
    while temp <= temp_max:
        temp_millidegrees = int(temp * 1000)
        comp_ppm = -(float(poly(temp)) - baseline)
        entries.append((temp_millidegrees, comp_ppm))
        temp += step
    return entries


def main() -> None:
    filepath = sys.argv[1] if len(sys.argv) > 1 else "plot_data.txt"

    temps, freqs = load_data(filepath)
    print(f"Loaded {len(temps)} samples")
    print(f"Temperature range: {temps.min():.1f}C - {temps.max():.1f}C")
    print(f"Frequency range: {freqs.min():.3f} - {freqs.max():.3f} ppm")
    print()

    poly, coeffs = fit_quadratic(temps, freqs)
    print(f"Quadratic fit: {coeffs[0]:.6f}*T^2 + {coeffs[1]:.6f}*T + {coeffs[2]:.6f}")
    print()

    if abs(coeffs[0]) < 1e-9:
        ref_temp = float(np.mean(temps))
        print(f"Reference temperature: {ref_temp:.2f}C (mean; fit is nearly linear)")
    else:
        ref_temp = float(-coeffs[1] / (2 * coeffs[0]))
        ref_temp = float(np.clip(ref_temp, temps.min(), temps.max()))
        print(f"Reference temperature: {ref_temp:.2f}C (fitted turnover point)")
    print(f"Reference frequency : {poly(ref_temp):.6f} ppm")
    print()

    # Show how well the fit matches at a few points
    print("Fit check (sample temperatures):")
    for t in np.linspace(temps.min(), temps.max(), 5):
        print(f"  {t:.1f}C -> predicted: {poly(t):.3f} ppm")
    print()

    # Generate table with 2C padding beyond observed range
    temp_min = np.floor(temps.min() / 0.5) * 0.5 - 2.0
    temp_max = np.ceil(temps.max() / 0.5) * 0.5 + 2.0

    entries = generate_tempcomp(poly, temp_min, temp_max, ref_temp)

    # Write tempcomp file
    outfile = "chrony.tempcomp"
    with open(outfile, "w") as f:
        for temp_md, comp in entries:
            f.write(f"{temp_md} {comp:.6f}\n")

    print(f"Generated {outfile} with {len(entries)} entries")
    print(f"Range: {temp_min:.1f}C to {temp_max:.1f}C (0.5C steps)")
    print()
    print("tempcomp file contents:")
    print("-" * 30)
    with open(outfile, "r") as f:
        print(f.read())


if __name__ == "__main__":
    main()
