/*
 * cpufreq_acacia.c - The "Acacia" High Performance Governor
 *
 * Copyright (C) 2024 techyguyperplexable
 *
 * This driver forces the CPU to run at the maximum allowed frequency
 * at all times. It ignores idle states and workload.
 *
 * Licensed under the GPLv2.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/cpufreq.h>
#include <linux/init.h>
#include <linux/module.h>

static void cpufreq_acacia_limits(struct cpufreq_policy *policy)
{
	pr_debug("setting to %u kHz\n", policy->max);
	__cpufreq_driver_target(policy, policy->max, CPUFREQ_RELATION_H);
}

static struct cpufreq_governor cpufreq_gov_acacia = {
	.name		= "acacia",
	.limits		= cpufreq_acacia_limits,
	.owner		= THIS_MODULE,
};

static int __init cpufreq_gov_acacia_init(void)
{
	pr_info("Acacia: Max performance governor loaded.\n");
	return cpufreq_register_governor(&cpufreq_gov_acacia);
}

static void __exit cpufreq_gov_acacia_exit(void)
{
	cpufreq_unregister_governor(&cpufreq_gov_acacia);
}

MODULE_AUTHOR("techyguyperplexable");
MODULE_DESCRIPTION("Acacia - Max Frequency Governor");
MODULE_LICENSE("GPL");

#ifdef CONFIG_CPU_FREQ_DEFAULT_GOV_ACACIA
struct cpufreq_governor *cpufreq_default_governor(void)
{
	return &cpufreq_gov_acacia;
}
#endif

fs_initcall(cpufreq_gov_acacia_init);
module_exit(cpufreq_gov_acacia_exit);
