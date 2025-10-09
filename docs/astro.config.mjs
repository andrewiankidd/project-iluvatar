import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
    site: 'https://andrewiankidd.github.io/project-iluvatar',
	base: '/project-iluvatar',
    server: {
        host: true,
    },
    redirects: {
        // match doesn't include base, but destination does
        '/guides/netboot/0-index': {
          status: 307,
          destination: '/project-iluvatar/guides/netboot/index',
        },
    },
    integrations: [
		starlight({
			title: 'project-iluvatar',
			social: {
				github: 'https://github.com/andrewiankidd/project-iluvatar',
			},
			sidebar: [
				{
					label: 'About',
					items: [
						{ label: 'Goals', link: '/about/' },
						{ label: 'Implementation', link: '/about/1-implementation/' },
						{ label: 'Resources', link: '/about/99-links/' },
					],
				},
				{
					label: 'Architecture',
					items: [
						{ label: 'Overview', link: '/architecture/' },
						{ label: 'Infrastructure Layers', link: '/architecture/infrastructure-layers/' },
						{ label: 'Naming & Conventions', link: '/architecture/naming-conventions/' },
						{
							label: 'Ainur (ARM Bootstrap Cluster)',
							items: [
								{ label: 'Software', link: '/architecture/arm/software/' },
								{ label: 'Hardware', link: '/architecture/arm/hardware/' },
							],
						},
						{
							label: 'Arda (x86 Workload Cluster)',
							items: [
								{ label: 'Software', link: '/architecture/x86/software/' },
								{ label: 'Hardware', link: '/architecture/x86/hardware/' },
							],
						},
						{
							label: 'Other / Miscellaneous',
							items: [
								{ label: 'Software', link: '/architecture/etc/software/' },
								{ label: 'Hardware', link: '/architecture/etc/hardware/' },
							],
						},
						{ label: 'Diagram', link: '/architecture/diagram/' },
					],
				},
				{
					label: 'Getting Started',
					items: [
						{ label: 'Overview', link: '/getting-started/' },
						{ label: 'Requirements', link: '/getting-started/requirements/' },
						{
							label: 'Bootstrap Ainur (Pi Cluster)',
							items: [
								{ label: 'Flashing Image & Cloud Config', link: '/getting-started/bootstrap-ainur/flashing-image-cloud-config/' },
								{ label: 'First Boot', link: '/getting-started/bootstrap-ainur/first-boot/' },
								{ label: 'K3s Setup', link: '/getting-started/bootstrap-ainur/k3s-setup/' },
							],
						},
						{
							label: 'Bootstrap Arda (x86 Cluster)',
							items: [
								{ label: 'PXE Boot & Talos Install', link: '/getting-started/bootstrap-arda/pxe-boot-talos/' },
								{ label: 'Joining Nodes', link: '/getting-started/bootstrap-arda/joining-nodes/' },
								{ label: 'Verifying Cluster', link: '/getting-started/bootstrap-arda/verifying-cluster/' },
							],
						},
						{
							label: 'Deploy Core Workloads',
							items: [
								{ label: 'Argo CD', link: '/getting-started/deploy-core-workloads/argo-cd/' },
								{ label: 'Longhorn', link: '/getting-started/deploy-core-workloads/longhorn/' },
								{ label: 'Velero', link: '/getting-started/deploy-core-workloads/velero/' },
							],
						},
					],
				},
				{
					label: 'Guides',
					items: [
						{
							label: 'Netbooting Raspberry Pi',
							items: [
								{ label: 'How Pi Boot Works', link: '/guides/netboot/' },
								{ label: 'Preparing Pi for Netboot', link: '/guides/netboot/1-pi-prep/' },
								{ label: 'Preparing a Netboot Server', link: '/guides/netboot/2-srv-prep/' },
								{ label: 'Serving Pi Images', link: '/guides/netboot/3-os-prep/' },
								{ label: 'Booting for the First Time', link: '/guides/netboot/4-pi-boot/' },
								{ label: 'Ubuntu Server Cloud Config', link: '/guides/netboot/5-ubuntuserver-cloudconfig/' },
							],
						},
						{
							label: 'Netbooting x86',
							items: [
								{ label: 'How x86 PXE Works', link: '/guides/netbooting-x86/' },
								{ label: 'PXE / DHCP / TFTP Basics', link: '/guides/netbooting-x86/pxe-dhcp-tftp-basics/' },
								{ label: 'UEFI vs Legacy Boot', link: '/guides/netbooting-x86/uefi-vs-legacy-boot/' },
								{ label: 'Serving Talos via PXE', link: '/guides/netbooting-x86/serving-talos-via-pxe/' },
							],
						},
						{ label: 'Talos Basics & Bootstrapping', link: '/guides/declarative-cluster/' },
						{ label: 'GitOps with Argo CD', link: '/guides/declarative-cluster/2-argo/' },
						{ label: 'Longhorn & Velero', link: '/guides/declarative-cluster/5-replication/' },
						{ label: 'Monitoring & Observability', link: '/guides/monitoring-observability/' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'Automation Tasks', link: '/reference/bootstrap-automation/' },
						{ label: 'Timings', link: '/reference/timings/' },
						{ label: 'DNS & DHCP Layout', link: '/reference/dns-dhcp-layout/' },
						{ label: 'PXE Server Config Examples', link: '/reference/pxe-server-config/' },
						{ label: 'Cluster Storage Notes', link: '/reference/cluster-storage-notes/' },
						{ label: 'Miscellaneous', link: '/reference/miscellaneous/' },
					],
				},
			],
		}),
	],
});
