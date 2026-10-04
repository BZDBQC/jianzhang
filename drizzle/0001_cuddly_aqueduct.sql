CREATE TABLE `auth_challenges` (
	`id` text PRIMARY KEY NOT NULL,
	`phone_hash` text NOT NULL,
	`code_hash` text NOT NULL,
	`phone_masked` text NOT NULL,
	`expires_at` integer NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`state` text NOT NULL,
	`consume_token` text DEFAULT '' NOT NULL
);
--> statement-breakpoint
CREATE TABLE `auth_limits` (
	`key` text PRIMARY KEY NOT NULL,
	`window_start` integer NOT NULL,
	`count` integer NOT NULL,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `auth_sessions` (
	`token_hash` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`phone_masked` text NOT NULL,
	`expires_at` integer NOT NULL
);
