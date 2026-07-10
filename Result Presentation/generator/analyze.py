"""Summarize the 3-dataset A/B: per-dataset stats + averaged-across-datasets."""
import csv, statistics, sys
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else "ab_multi.csv"
rows = list(csv.DictReader(open(path)))

# group measured (non-warmup) runs by (stack, dataset)
groups = defaultdict(list)
for r in rows:
    if not r["run"].isdigit():
        continue
    groups[(r["stack"], int(r["dataset"]))].append({
        "lat": float(r["latency_s"]), "calls": int(r["llm_calls"]), "valid": int(r["valid"])
    })

stacks = sorted({s for s, _ in groups})
print(f"{'stack':<12}{'ds':<4}{'valid/n':<9}{'med_lat(valid)':<16}{'mean_calls(valid)':<18}")
print("-" * 60)
summary = {}
for stack in stacks:
    ds_medians, ds_rates, ds_calls, pooled_valid_lat, pooled_valid_calls = [], [], [], [], []
    tot_valid = tot_n = 0
    for ds in sorted(d for s, d in groups if s == stack):
        g = groups[(stack, ds)]
        n = len(g); valid = [x for x in g if x["valid"] == 1]
        tot_valid += len(valid); tot_n += n
        med = statistics.median([x["lat"] for x in valid]) if valid else float("nan")
        mc = statistics.mean([x["calls"] for x in valid]) if valid else float("nan")
        if valid:
            ds_medians.append(med); ds_calls.append(mc)
            pooled_valid_lat += [x["lat"] for x in valid]
            pooled_valid_calls += [x["calls"] for x in valid]
        ds_rates.append(len(valid) / n)
        print(f"{stack:<12}{ds:<4}{f'{len(valid)}/{n}':<9}{med:<16.1f}{mc:<18.1f}")
    summary[stack] = {
        "avg_of_ds_medians": statistics.mean(ds_medians) if ds_medians else float("nan"),
        "pooled_median_lat": statistics.median(pooled_valid_lat) if pooled_valid_lat else float("nan"),
        "pooled_mean_lat": statistics.mean(pooled_valid_lat) if pooled_valid_lat else float("nan"),
        "avg_calls": statistics.mean(ds_calls) if ds_calls else float("nan"),
        "valid_rate": tot_valid / tot_n if tot_n else float("nan"),
        "tot_valid": tot_valid, "tot_n": tot_n,
        "n_valid_lat": len(pooled_valid_lat),
    }

print("\n" + "=" * 64)
print("AVERAGED ACROSS 3 DATASETS (per stack)")
print("=" * 64)
print(f"{'stack':<14}{'valid rate':<14}{'avg-of-medians':<17}{'pooled median':<16}{'avg calls':<11}")
for stack in stacks:
    s = summary[stack]
    print(f"{stack:<14}{f'{s['tot_valid']}/{s['tot_n']} ({100*s['valid_rate']:.0f}%)':<14}"
          f"{s['avg_of_ds_medians']:<17.1f}{s['pooled_median_lat']:<16.1f}{s['avg_calls']:<11.1f}")
print(f"\n(pooled median = median of all {'/'.join(str(summary[s]['n_valid_lat']) for s in stacks)} valid runs; "
      "avg-of-medians = mean of the 3 per-dataset medians)")
