import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import mermaid from 'astro-mermaid';

// https://astro.build/config
export default defineConfig({
	site: 'https://andrewiankidd.github.io/project-iluvatar',
	base: '/project-iluvatar',
	server: {
		host: true,
	},
	integrations: [
		mermaid({
      theme: 'forest',
      autoTheme: true
    }),
		starlight({
			title: 'project-iluvatar',
				social: [
					{label: 'GitHub', href: 'https://github.com/andrewiankidd/project-iluvatar', icon: 'github' },
				],
			sidebar: [
				{
					label: 'About',
					collapsed: true,
					autogenerate: { directory: 'About', exclude: ['drafts'] },
				},
				{
					label: 'Architecture',
					collapsed: true,
					autogenerate: { directory: 'Architecture', exclude: ['drafts'] },
				},
				{
					label: 'Getting Started',
					collapsed: true,
					autogenerate: { directory: 'Getting Started', exclude: ['drafts'] },
				},
				{
					label: 'Guides',
					collapsed: true,
					items: [
						{
							label: '📃 Overview',
							slug: 'guides',
						},
						{
							label: 'Diskless Pi Netboot',
							collapsed: true,
							autogenerate: { directory: 'Guides/Netbooting Raspberry Pi', exclude: ['drafts'] },
						},
						{
							label: 'Ephemeral K3s Cluster',
							collapsed: true,
							autogenerate: { directory: 'Guides/Ephemeral K3s Cluster', exclude: ['drafts'] },
						},
						{
							label: 'Self Signed Cluster SSO',
							collapsed: true,
							autogenerate: { directory: 'Guides/Self Signed Cluster SSO', exclude: ['drafts'] },
						},
						{
							label: 'Bootstrapping Kubernetes From Kubernetes',
							collapsed: true,
							autogenerate: { directory: 'Guides/Netbooting Pi from Kubernetes', exclude: ['drafts'] },
						},
						{
							label: 'Netbooting x86',
							collapsed: true,
							autogenerate: { directory: 'Guides/Netbooting x86', exclude: ['drafts'] },
						},
						{
							label: 'Other',
							collapsed: true,
							autogenerate: { directory: 'Guides/Other', exclude: ['drafts'] },
						},
					],
				},
				{
					label: 'Reference',
					collapsed: true,
					autogenerate: { directory: 'reference', exclude: ['drafts'] }
				}
			],
		}),
	],
});
