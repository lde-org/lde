/// <reference types="astro/client" />

interface GithubUser {
	login: string;
	id: number;
	avatarUrl: string | null;
}

interface GithubSession {
	accessToken: string;
	refreshToken?: string;
	expiresAt?: number;
	refreshExpiresAt?: number;
	user: GithubUser;
}

declare namespace App {
	interface SessionData {
		github?: GithubSession;
		oauthState?: string;
		returnTo?: string;
		lastNamespaceRequest?: number;
		lastOwnerRequest?: number;
	}

	interface Locals {
		runtime?: {
			env?: {
				GITHUB_CLIENT_ID?: string;
				GITHUB_CLIENT_SECRET?: string;
				REGISTRY_REPO?: string;
				REGISTRY_BRANCH?: string;
				SITE_URL?: string;
			};
		};
	}
}
