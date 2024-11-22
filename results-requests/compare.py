import json

import matplotlib.pyplot as plt
import numpy as np


# Function to read JSON files
def read_json_file(filename):
    with open(filename) as f:
        return json.load(f)


# List of frameworks and their files
frameworks = {
    "Bun": ["bun_no_schema.json", "bun_schema.json"],
    "Elysia": ["elysia_no_schema.json", "elysia_schema.json"],
    "Encore": ["encore_no_schema.json", "encore_schema.json"],
    "Express": ["express_no_schema.json", "express_schema.json"],
    "Fastify": ["fastify_no_schema.json", "fastify_schema.json"],
    "Fastify v5": ["fastify-v5_no_schema.json", "fastify-v5_schema.json"],
    "Hono": ["hono_no_schema.json", "hono_schema.json"],
}

# Collect data
rps_no_schema = []
rps_schema = []
latency_no_schema = []
latency_schema = []
framework_names = []

for framework, files in frameworks.items():
    framework_names.append(framework)

    # No schema
    data = read_json_file(files[0])
    rps_no_schema.append(data["summary"]["requestsPerSec"])
    latency_no_schema.append(data["summary"]["average"] * 1000)  # Convert to ms

    # With schema
    data = read_json_file(files[1])
    rps_schema.append(data["summary"]["requestsPerSec"])
    latency_schema.append(data["summary"]["average"] * 1000)  # Convert to ms

# Create figure with two subplots
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10))

# Set width of bars
width = 0.35
x = np.arange(len(framework_names))

# RPS comparison
rps1 = ax1.bar(x - width / 2, rps_no_schema, width, label="No Schema")
rps2 = ax1.bar(x + width / 2, rps_schema, width, label="With Schema")

ax1.set_ylabel("Requests per Second")
ax1.set_title(
    "Framework Performance Comparison - Requests per Second (Higher is Better)"
)
ax1.set_xticks(x)
ax1.set_xticklabels(framework_names)
ax1.legend()

# Add value labels on top of bars
for bars in [rps1, rps2]:
    for bar in bars:
        height = bar.get_height()
        ax1.text(
            bar.get_x() + bar.get_width() / 2.0,
            height,
            f"{int(height):,}",
            ha="center",
            va="bottom",
        )

# Latency comparison
lat1 = ax2.bar(x - width / 2, latency_no_schema, width, label="No Schema")
lat2 = ax2.bar(x + width / 2, latency_schema, width, label="With Schema")

ax2.set_ylabel("Average Latency (ms)")
ax2.set_title("Framework Performance Comparison - Average Latency (Lower is Better)")
ax2.set_xticks(x)
ax2.set_xticklabels(framework_names)
ax2.legend()

# Add value labels on top of bars
for bars in [lat1, lat2]:
    for bar in bars:
        height = bar.get_height()
        ax2.text(
            bar.get_x() + bar.get_width() / 2.0,
            height,
            f"{height:.2f}",
            ha="center",
            va="bottom",
        )

# Adjust layout and save
plt.tight_layout()
plt.savefig("framework_comparison.png", dpi=300, bbox_inches="tight")
print("Chart has been saved as 'framework_comparison.png'")
