#!/usr/bin/env node
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { PersistentStack } from '../lib/persistent-stack';
import { RecoveryStack } from '../lib/recovery-stack';

const app = new cdk.App();

// Deployment-specific settings (domain, alert email, region) live in aio.config.json, which is gitignored
// so the repo carries no personal data. Copy aio.config.example.json to start. Any key can also be given
// as CDK context, which wins over the file: -c aio:domain=dr.example.com
const CONFIG_FILE = path.join(__dirname, '..', 'aio.config.json');
const fileConfig: Record<string, string> = fs.existsSync(CONFIG_FILE)
  ? JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))
  : {};
function setting(key: string): string;
function setting(key: string, optional: true): string | undefined;
function setting(key: string, optional = false): string | undefined {
  const value = app.node.tryGetContext(`aio:${key}`) ?? fileConfig[key];
  if (!value && !optional) {
    throw new Error(
      `Missing setting "${key}". Copy aio.config.example.json to aio.config.json and fill it in ` +
        `(or pass -c aio:${key}=...).`,
    );
  }
  return value;
}

const region = setting('region');
const domain = setting('domain');
const streamsHost = setting('streamsHost', true) ?? `streams.${domain}`;
const metaHost = setting('metaHost', true) ?? `meta.${domain}`;
const alertEmail = setting('alertEmail');
const instanceType = setting('instanceType', true) ?? 't3a.small';

// CDK_DEFAULT_ACCOUNT is resolved from the active AWS credentials (use AWS_PROFILE=Admin).
const env = { account: process.env.CDK_DEFAULT_ACCOUNT, region };

// Always-on, cheap, never destroyed: backup bucket, DNS zone, IAM for the PC agent.
new PersistentStack(app, 'AioPersistent', {
  env,
  domain,
  alertEmail,
  terminationProtection: true,
  description: 'AIO DR - persistent resources (S3 backups, Route53 zone, PC agent IAM)',
});

// On-demand cold standby. Its template is standalone; publish it with scripts/publish-template.sh.
new RecoveryStack(app, 'AioRecovery', {
  env,
  domain,
  streamsHost,
  metaHost,
  instanceType,
  description: 'AIO DR - cold standby (EC2 + Caddy + IP-allowlisted SG); delete the stack when the PC is back',
});
