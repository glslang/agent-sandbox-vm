# Feasibility: Native Windows-on-ARM via `Hypervisor.framework`

> **Status:** analysis / scoping only. Nothing here is implemented. `vmctl` boots guests through
> the high-level `Virtualization.framework` (VZ) today; this document scopes what it would take to
> support a *supported* Windows 11 ARM64 guest by dropping to the low-level `Hypervisor.framework`
> (HVF) instead.

## Verdict up front

Building a from-scratch HVF virtual machine monitor (VMM) that boots a supported Windows 11 ARM64
is a **multi-person-year effort, roughly equivalent to re-implementing QEMU's `virt` machine +
EDK2 firmware + swtpm + the virtio-win driver story**. It is unquestionably *possible* — UTM and
QEMU do exactly this on the same HVF API — but it is wildly out of proportion to what this toolkit
is.

**Recommendation:** if Windows support is genuinely wanted, **wrap UTM/QEMU** (option B below) —
same HVF underneath, but all the hard parts are already solved and maintained. Otherwise keep the
status quo (VZ generic-EFI marked experimental, users pointed at Parallels/UTM). A from-scratch VMM
(option A) is not recommended for this repo.

---

## 1. Why HVF is even in the conversation

Apple ships **two** virtualization APIs, and the difference is the entire story:

| | `Hypervisor.framework` (HVF, low-level) | `Virtualization.framework` (VZ, high-level) |
|---|---|---|
| What it gives you | Raw CPU + memory virtualization: `hv_vm_create`, vCPU create/run, register access, stage-2 (guest-physical→host) mapping via `hv_vm_map`, VM-exit trapping, and — in newer macOS — an in-kernel virtual GIC/timer (`hv_gic_*`) | A prebuilt machine: fixed virtio device set, EFI/macOS boot loaders, macOS IPSW restore |
| You must build | **Everything else** — firmware, ACPI, TPM, device models, boot | Almost nothing; Apple owns the machine |
| Windows-relevant gaps | None *by construction* — you can add anything | **No vTPM, no Secure Boot key mgmt, no custom devices, no Windows install path** |
| Used by | **Parallels, VMware Fusion, UTM/QEMU (hvf accel)** | Docker Desktop, **this repo's `vmctl`** |

The one sentence that drives this whole document:

> **HVF virtualizes a CPU and its memory. A bootable, Windows-11-ready *machine* is entirely yours
> to build.**

That is why HVF unblocks Windows in principle (you can add a vTPM, Secure Boot, and whatever
devices you like) and simultaneously why it is enormous (you have to add *all* of them).

`vmctl`'s current Windows attempt lives in `buildGenericEFIConfiguration`
(`Sources/vmctl/main.swift:630`) using `VZGenericPlatformConfiguration` + `VZEFIBootLoader`
(`main.swift:639-643`). It will power on and reach the Windows installer, but there is no vTPM and
no install automation, so a stock Windows 11 setup dead-ends — see the README "Windows Status".

## 2. Gap analysis — what you build on top of HVF

Each of these is a component that VZ hides and HVF omits. Windows-on-ARM needs essentially all of
them.

| Component | Why Windows 11 ARM needs it | Reuse candidate | Effort | Risk |
|-----------|-----------------------------|-----------------|--------|------|
| VMM core / MMIO dispatch / DMA | Every device access is a VM-exit you route by hand | — (bespoke) | High | Med |
| GICv3 interrupt controller + generic timer | IRQ delivery and SMP scheduling | `hv_gic_*` (macOS 15+) or emulate GICv3 | Med | Med |
| UEFI firmware | Windows-on-ARM boots via UEFI | **EDK2 / TianoCore ArmVirt** | High | Med |
| ACPI tables (MADT/GTDT/FADT/DSDT/`TPM2`…) | Windows-on-ARM consumes **ACPI, not device tree**, and is far pickier than Linux | generate à la QEMU | High | **High** |
| vTPM 2.0 (CRB/MMIO iface + `TPM2` table) | Windows 11 setup hard-requires TPM 2.0 | **libtpms / swtpm** | Med | Med |
| Secure Boot (PK/KEK/db/dbx, authenticated vars) | Win11 expects UEFI Secure Boot; chain to Microsoft UEFI CA | EDK2 SecureBoot | Med | Med |
| virtio devices (block/net/gpu/input/console) | Storage, network, display, input, serial | QEMU device models | High | Med |
| **Signed** virtio ARM64 guest drivers | Guest can't drive virtio devices without them | **virtio-win** (signing + stability caveat) | Med | **High** |
| CPU identity (MIDR, `ID_AA64*`) + feature exposure | Wrong/mismatched IDs → early BSOD | mirror QEMU `-cpu host`/`max` | Med | **High** |
| PSCI (SMC/HVC handlers) | CPU on/off, reset, shutdown, SMP bring-up | implement per spec | Low | Low |
| Debug plumbing (serial + KDNET) | Boot failures are otherwise silent hangs / BSODs | — | Med | Med |

Notes on the highest-risk rows:

- **ACPI** is the classic wall. Linux tolerates a lot; Windows-on-ARM's HAL expects tables shaped
  like hardware it already ships drivers for. Small deviations manifest as a bugcheck before you get
  any output.
- **CPU identity** is subtle: you must present ID registers Windows accepts *and* that match the
  features you actually virtualize on the Apple core, or it bugchecks during boot.
- **Signed virtio drivers** are exactly the problem the commercial products solve with their own
  signed guest tools; relying on community virtio-win packages carries signing/stability risk.

## 3. Non-technical gates

- **Licensing.** Microsoft only formally authorizes Windows 11 ARM64 on specific virtualization
  solutions (e.g. Parallels Desktop). A home-grown VMM is in a grey area; this needs a deliberate
  decision, not a footnote.
- **Entitlements & signing.** HVF requires the `com.apple.security.hypervisor` entitlement. The
  binary today carries only `com.apple.security.virtualization` (`vmctl.entitlements:6`), so this is
  a new entitlement and a signing change. Bridged networking additionally needs
  `com.apple.vm.networking` under a real signing identity; ad-hoc signing covers only the basic
  local case.
- **Maintenance surface.** You would own a moving target: Windows-on-ARM servicing changes, driver
  signing, EDK2/ACPI updates, and macOS HVF API churn across releases — indefinitely.

## 4. Phased proof-points (how you'd de-risk incrementally)

Each milestone is a concrete "it boots to X" checkpoint. Do **not** attempt them out of order — each
depends on the components proven by the previous one.

1. **HVF hello-world.** Run a trivial ARM64 payload under `hv_vm_create` + one vCPU; handle a single
   MMIO exit. *Proves:* VMM core, memory mapping, exit loop. *Failure mode:* entitlement/signing or
   stage-2 mapping mistakes.
2. **UEFI shell.** EDK2 ArmVirt firmware reaches the interactive UEFI shell, no OS. *Proves:*
   firmware, GIC/timer, serial console. *Failure mode:* firmware ↔ platform (GIC base, memory map)
   mismatch.
3. **Windows installer UI.** Windows ARM64 setup boots to its first screen. *Proves:* ACPI tables,
   virtio-block (or USB media), input, correct CPU identity. *Failure mode:* ACPI-driven early
   bugcheck; wrong `ID_AA64*`.
4. **Install completes to disk.** Setup finishes onto the NVMe/virtio disk. *Proves:* vTPM 2.0 and
   Secure Boot (or a documented, deliberate bypass). *Failure mode:* "This PC can't run Windows 11"
   TPM gate; auth-variable handling.
5. **Windows desktop, usable.** Networking + display via virtio-win drivers, entropy, clipboard-less
   but functional. *Proves:* signed virtio guest drivers, virtio-net/gpu. *Failure mode:* unsigned
   driver rejection; display/input instability.
6. **Automation parity with the VZ path.** `create / install / run / stop / snapshot / copy-out`,
   the VirtioFS-style shared dir, and isolated/NAT networking all working through the new backend.
   *Proves:* integration with the existing bundle/config/snapshot conventions.

## 5. Effort and the realistic alternatives

- **A — From-scratch HVF VMM.** The full §2 stack. Multi-person-year; maximum control; matches the
  engineering scale of Parallels/VMware/UTM. **Not recommended** for this toolkit.
- **B — Wrap UTM/QEMU (recommended if Windows is wanted).** QEMU's `hvf` accelerator *is* HVF
  underneath and already ships EDK2 firmware, generated ACPI, swtpm-backed vTPM, virtio devices, and
  virtio-win guidance. `vmctl` would orchestrate a `qemu-system-aarch64` (or UTM) process instead of
  a `VZVirtualMachine`, reusing the existing bundle layout, `config.json`, shared directory, and
  snapshot conventions. **Weeks, not years.** This is already what the README recommends.
- **C — Status quo.** Keep VZ generic-EFI labelled experimental and point users to Parallels/UTM.
  Zero new maintenance.

| Criterion | A: from-scratch HVF | B: wrap UTM/QEMU | C: status quo |
|-----------|---------------------|------------------|---------------|
| Effort | Multi-person-year | Weeks | None |
| Control over the stack | Total | Moderate (QEMU's choices) | N/A |
| Licensing risk | High (grey area) | Medium | None (defer to user's tool) |
| Ongoing maintenance | Very high | Medium | None |
| Fit with repo's "native VZ" identity | Poor (huge divergence) | Medium (adds a runtime dep) | Perfect |

## 6. Recommendation & open decisions

**Recommendation:** choose **B** if Windows support is a real requirement; otherwise **C**. Do not
pursue **A** in this repository.

Open questions the reader must answer before committing to anything:

1. Is **ARM64-only** Windows acceptable? (Apple Silicon can't hardware-virtualize x86; x86 apps run
   only under Windows' own emulation. There is no native x64 Windows guest.)
2. Is the **Microsoft licensing** posture for Windows 11 ARM on a non-authorized VMM acceptable?
3. Is a **QEMU/UTM runtime dependency** acceptable in a repo whose selling point is a *native*
   `Virtualization.framework` implementation with no external hypervisor?

If the answer to (3) is "no," the honest conclusion is **C** plus a clear pointer to Parallels/UTM —
which is essentially where the project already stands.
