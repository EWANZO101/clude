"""Representative real-world server hardware catalog with ESTIMATED monthly
rental pricing (GBP) for the /build-server configurator.

These are not live vendor prices — they're reasonable estimates modelled on
typical dedicated-server component upcharges, meant to give customers a
ballpark monthly cost while building a configuration. Admins can edit any
row's price under /admin/hardware/<category> at any time.
"""

BRANDS = [
    ("Intel", "intel"),
    ("AMD", "amd"),
    ("NVIDIA", "nvidia"),
    ("Samsung", "samsung"),
    ("SK hynix", "sk-hynix"),
    ("Micron", "micron"),
    ("Kingston", "kingston"),
    ("Seagate", "seagate"),
    ("Western Digital", "western-digital"),
    ("Solidigm", "solidigm"),
    ("Broadcom", "broadcom"),
    ("Dell", "dell"),
    ("Supermicro", "supermicro"),
    ("Seasonic", "seasonic"),
    ("Delta Electronics", "delta-electronics"),
]

# --- CPUs ---------------------------------------------------------------
CPUS = [
    # (brand, model, sku, cores, threads, base_ghz, boost_ghz, tdp, cache_mb, socket, price_gbp_month)
    ("Intel", "Xeon Silver 4410Y", "PN-4410Y", 12, 24, 2.0, 3.9, 150, 30, "LGA4677", 22),
    ("Intel", "Xeon Gold 5416S", "PN-5416S", 16, 32, 2.0, 4.0, 150, 30, "LGA4677", 34),
    ("Intel", "Xeon Gold 6430", "PN-6430", 32, 64, 2.1, 3.4, 270, 60, "LGA4677", 62),
    ("Intel", "Xeon Gold 6448Y", "PN-6448Y", 32, 64, 2.1, 4.1, 225, 60, "LGA4677", 78),
    ("Intel", "Xeon Gold 6448H", "PN-6448H", 32, 64, 2.4, 4.1, 250, 60, "LGA4677", 82),
    ("Intel", "Xeon Platinum 8460Y+", "PN-8460Y", 40, 80, 2.0, 3.7, 300, 60, "LGA4677", 145),
    ("Intel", "Xeon Platinum 8592+", "PN-8592", 64, 128, 1.9, 3.9, 350, 320, "LGA4677", 220),
    ("Intel", "Xeon Gold 6248R", "PN-6248R", 24, 48, 3.0, 4.0, 205, 35.75, "LGA3647", 55),
    ("Intel", "Xeon E-2388G", "PN-E2388G", 8, 16, 3.2, 5.1, 95, 16, "LGA1200", 20),
    ("AMD", "EPYC 9124", "PN-9124", 16, 32, 3.0, 3.7, 200, 64, "SP5", 40),
    ("AMD", "EPYC 9354", "PN-9354", 32, 64, 3.25, 3.8, 280, 256, "SP5", 88),
    ("AMD", "EPYC 9454", "PN-9454", 48, 96, 2.75, 3.8, 290, 256, "SP5", 128),
    ("AMD", "EPYC 9554", "PN-9554", 64, 128, 3.1, 3.75, 360, 256, "SP5", 175),
    ("AMD", "EPYC 9654", "PN-9654", 96, 192, 2.4, 3.7, 360, 384, "SP5", 245),
    ("AMD", "EPYC 7443", "PN-7443", 24, 48, 2.85, 4.0, 200, 128, "SP3", 60),
    ("AMD", "EPYC 7513", "PN-7513", 32, 64, 2.6, 3.65, 200, 128, "SP3", 75),
    ("AMD", "EPYC 7713", "PN-7713", 64, 128, 2.0, 3.675, 225, 256, "SP3", 130),
    ("AMD", "Ryzen 9 7950X", "PN-7950X", 16, 32, 4.5, 5.7, 170, 64, "AM5", 30),
]

# --- RAM ------------------------------------------------------------------
RAM_MODULES = [
    # (brand, model, sku, ddr_gen, capacity_gb, speed_mhz, ecc, registered, price_gbp_month)
    ("Samsung", "32GB DDR4 3200MHz RDIMM ECC", "M393A4K40DB3", "DDR4", 32, 3200, True, True, 6),
    ("Samsung", "64GB DDR4 3200MHz RDIMM ECC", "M393A8G40AB2", "DDR4", 64, 3200, True, True, 11),
    ("Samsung", "32GB DDR5 4800MHz RDIMM ECC", "M321R4GA3BB6", "DDR5", 32, 4800, True, True, 9),
    ("Samsung", "64GB DDR5 4800MHz RDIMM ECC", "M321R8GA3BB6", "DDR5", 64, 4800, True, True, 16),
    ("Samsung", "128GB DDR5 4800MHz RDIMM ECC", "M321RYGA3BB6", "DDR5", 128, 4800, True, True, 30),
    ("SK hynix", "16GB DDR4 2933MHz RDIMM ECC", "HMA82GR7CJR8N", "DDR4", 16, 2933, True, True, 4),
    ("SK hynix", "32GB DDR4 3200MHz RDIMM ECC", "HMA84GR7CJR4N", "DDR4", 32, 3200, True, True, 6),
    ("SK hynix", "64GB DDR5 4800MHz RDIMM ECC", "HMCG88AGBRA109N", "DDR5", 64, 4800, True, True, 15),
    ("Micron", "32GB DDR4 3200MHz RDIMM ECC", "MTA36ASF4G72PZ", "DDR4", 32, 3200, True, True, 6),
    ("Micron", "128GB DDR5 5600MHz RDIMM ECC", "MTC40F2046S1RC56BD1", "DDR5", 128, 5600, True, True, 32),
    ("Micron", "256GB DDR5 5600MHz RDIMM ECC", "MTC80F2046S1RC56BD1", "DDR5", 256, 5600, True, True, 58),
    ("Kingston", "16GB DDR4 2666MHz RDIMM ECC", "KSM26RD8/16MEI", "DDR4", 16, 2666, True, True, 3),
    ("Kingston", "64GB DDR4 3200MHz RDIMM ECC", "KSM32RD4/64MER", "DDR4", 64, 3200, True, True, 11),
]

# --- Storage ----------------------------------------------------------------
STORAGE_DEVICES = [
    # (brand, model, sku, storage_type, capacity_gb, interface, form_factor, price_gbp_month)
    ("Seagate", "Exos X18 16TB", "ST16000NM000J", "hdd", 16000, "SATA III", "3.5in", 12),
    ("Seagate", "Exos X20 20TB", "ST20000NM007D", "hdd", 20000, "SAS 12Gb/s", "3.5in", 15),
    ("Seagate", "Exos 7E10 4TB", "ST4000NM000A", "hdd", 4000, "SATA III", "3.5in", 5),
    ("Western Digital", "Ultrastar DC HC550 16TB", "WUH721816ALE6L4", "hdd", 16000, "SATA III", "3.5in", 12),
    ("Western Digital", "Ultrastar DC HC560 20TB", "WUH722020ALE6L4", "hdd", 20000, "SATA III", "3.5in", 15),
    ("Samsung", "PM893 960GB Enterprise SATA SSD", "MZ7L3960HCJR", "sata_ssd", 960, "SATA III", "2.5in", 6),
    ("Samsung", "PM893 3.84TB Enterprise SATA SSD", "MZ7L33T8HBLT", "sata_ssd", 3840, "SATA III", "2.5in", 18),
    ("Micron", "5400 PRO 1.92TB SATA SSD", "MTFDDAK1T9TGA", "sata_ssd", 1920, "SATA III", "2.5in", 10),
    ("Samsung", "PM9A3 1.92TB NVMe SSD", "MZQL21T9HCJR", "nvme_ssd", 1920, "PCIe 4.0 x4", "U.2", 16),
    ("Samsung", "PM9A3 3.84TB NVMe SSD", "MZQL23T8HCLS", "nvme_ssd", 3840, "PCIe 4.0 x4", "U.2", 28),
    ("Samsung", "PM9A3 7.68TB NVMe SSD", "MZQL27T6HBLA", "nvme_ssd", 7680, "PCIe 4.0 x4", "U.2", 48),
    ("Micron", "7450 MAX 3.2TB NVMe SSD", "MTFDKCC3T2TFS", "nvme_ssd", 3200, "PCIe 4.0 x4", "U.3", 30),
    ("Micron", "7450 PRO 15.36TB NVMe SSD", "MTFDKCB15TFS", "nvme_ssd", 15360, "PCIe 4.0 x4", "U.3", 85,),
    ("Solidigm", "D7-P5520 3.84TB NVMe SSD", "SSDPF2KX038T1", "nvme_ssd", 3840, "PCIe 4.0 x4", "U.2", 27),
    ("Solidigm", "D7-P5520 7.68TB NVMe SSD", "SSDPF2KX076T1", "nvme_ssd", 7680, "PCIe 4.0 x4", "U.2", 46),
]

# --- GPUs -------------------------------------------------------------------
GPUS = [
    # (brand, model, sku, vram_gb, cores, power_w, pcie_gen, price_gbp_month)
    ("NVIDIA", "Tesla T4", "900-2G183-0000-000", 16, 2560, 70, "PCIe 3.0", 65),
    ("NVIDIA", "L4", "900-2G193-0000-000", 24, 7680, 72, "PCIe 4.0", 95),
    ("NVIDIA", "L40S", "900-2G133-0060-000", 48, 18176, 350, "PCIe 4.0", 210),
    ("NVIDIA", "RTX A6000", "900-5G133-2200-000", 48, 10752, 300, "PCIe 4.0", 190),
    ("NVIDIA", "RTX 4090", "900-1G136-2530-000", 24, 16384, 450, "PCIe 4.0", 145),
    ("NVIDIA", "A100 40GB PCIe", "900-21001-0000-000", 40, 6912, 250, "PCIe 4.0", 380),
    ("NVIDIA", "A100 80GB PCIe", "900-21001-0020-100", 80, 6912, 300, "PCIe 4.0", 440),
    ("NVIDIA", "H100 80GB PCIe", "900-21010-0000-000", 80, 14592, 350, "PCIe 5.0", 850),
    ("AMD", "Instinct MI210", "100-000000556", 64, 6656, 300, "PCIe 4.0", 320),
]

# --- Network cards ------------------------------------------------------------
NETWORK_CARDS = [
    # (brand, model, sku, port_count, port_type, speed_gbps, interface, price_gbp_month)
    ("Intel", "X550-T2 Dual-Port 10GBase-T", "X550T2", 2, "RJ45", 10, "PCIe 3.0 x4", 8),
    ("Intel", "X710-DA2 Dual-Port SFP+", "X710DA2", 2, "SFP+", 10, "PCIe 3.0 x8", 10),
    ("Intel", "E810-XXVDA2 Dual-Port SFP28", "E810XXVDA2", 2, "SFP28", 25, "PCIe 4.0 x8", 18),
    ("Broadcom", "NetXtreme BCM57414 Dual-Port 25GbE", "BCM57414", 2, "SFP28", 25, "PCIe 3.0 x8", 20),
    ("NVIDIA", "ConnectX-6 Dx Dual-Port 25GbE", "MCX623106AN-CDAT", 2, "SFP28", 25, "PCIe 4.0 x16", 25),
    ("NVIDIA", "ConnectX-6 Dx Dual-Port 100GbE", "MCX623106AC-CDAT", 2, "QSFP56", 100, "PCIe 4.0 x16", 60),
]

# --- RAID controllers -----------------------------------------------------
RAID_CONTROLLERS = [
    # (brand, model, sku, raid_levels, cache_mb, interface, port_count, price_gbp_month)
    ("Broadcom", "MegaRAID 9440-8i", "05-50011-00", ["0", "1", "5", "10"], 0, "PCIe 3.1 x8", 8, 10),
    ("Broadcom", "MegaRAID 9460-16i", "05-50024-00", ["0", "1", "5", "6", "10", "50", "60"], 4096, "PCIe 3.1 x8", 16, 22),
    ("Broadcom", "MegaRAID 9560-8i", "05-50077-00", ["0", "1", "5", "6", "10", "50", "60"], 4096, "PCIe 4.0 x8", 8, 26),
    ("Broadcom", "HBA 9500-16i", "05-50014-00", ["JBOD"], 0, "PCIe 4.0 x8", 16, 12),
    ("Dell", "PERC H755", "405-ABGT", ["0", "1", "5", "6", "10", "50", "60"], 8192, "PCIe 4.0 x8", 8, 28),
    ("Dell", "PERC H345", "405-ABEB", ["0", "1", "5", "10"], 0, "PCIe 3.0 x8", 8, 9),
]

# --- Power supplies -----------------------------------------------------------
POWER_SUPPLIES = [
    # (brand, model, sku, wattage, form_factor, efficiency, redundant, price_gbp_month)
    ("Delta Electronics", "DPS-550AB 550W Platinum", "DPS-550AB-13", 550, "1U", "Platinum", False, 4),
    ("Delta Electronics", "DPS-800AB 800W Platinum Redundant", "DPS-800AB-11", 800, "1U", "Platinum", True, 8),
    ("Delta Electronics", "DPS-1100AB 1100W Platinum Redundant", "DPS-1100AB-11", 1100, "1U", "Platinum", True, 11),
    ("Delta Electronics", "DPS-1600AB 1600W Titanium Redundant", "DPS-1600AB-11", 1600, "2U", "Titanium", True, 16),
    ("Delta Electronics", "DPS-2000AB 2000W Titanium Redundant", "DPS-2000AB-11", 2000, "2U", "Titanium", True, 21),
    ("Seasonic", "SS-460H2U 460W Platinum", "SS-460H2U", 460, "1U", "Platinum", False, 4),
    ("Seasonic", "SS-750HT2U 750W Titanium Redundant", "SS-750HT2U", 750, "1U", "Titanium", True, 9),
]

# --- Server chassis ------------------------------------------------------------
CHASSIS = [
    # (brand, model, sku, form_factor, rack_units, drive_bays, max_gpu, max_psu, dims, weight_kg, price_gbp_month)
    ("Supermicro", "SuperServer 1U 4x3.5\" Bay", "SYS-110P-WTR", "1U", 1, 4, 0, 2, "437x43x711mm", 12, 9),
    ("Supermicro", "SuperServer 2U 12x3.5\" Bay", "SYS-220U-TNR", "2U", 2, 12, 2, 2, "437x87x737mm", 22, 14),
    ("Supermicro", "SuperServer 2U GPU 8x2.5\" Bay", "SYS-220GQ-TNAR", "2U", 2, 8, 4, 2, "437x87x790mm", 28, 22),
    ("Supermicro", "SuperServer 4U GPU 8-GPU", "SYS-420GP-TNAR", "4U", 4, 24, 8, 4, "437x175x790mm", 55, 40),
    ("Dell", "PowerEdge R650 1U Chassis", "R650-CHASSIS", "1U", 1, 10, 0, 2, "434x43x772mm", 14, 10),
    ("Dell", "PowerEdge R750 2U Chassis", "R750-CHASSIS", "2U", 2, 16, 3, 2, "434x87x813mm", 24, 15),
    ("Dell", "PowerEdge R760xa 2U GPU Chassis", "R760XA-CHASSIS", "2U", 2, 8, 4, 2, "434x87x813mm", 30, 24),
]
