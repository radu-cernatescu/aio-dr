import * as cdk from 'aws-cdk-lib';
import * as cw from 'aws-cdk-lib/aws-cloudwatch';
import * as cwActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subs from 'aws-cdk-lib/aws-sns-subscriptions';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

export interface PersistentStackProps extends cdk.StackProps {
  /** Delegated subdomain served from Route53, e.g. aio.example.com */
  readonly domain: string;
  /** Where "PC is down" alerts are emailed (the subscription must be confirmed once via the email link). */
  readonly alertEmail: string;
}

/** SSM parameter names shared with scripts/ and RecoveryStack. */
export const PARAM = {
  bucket: '/aio/backup-bucket',
  zoneId: '/aio/hosted-zone-id',
  domain: '/aio/domain',
  // Maintained OUTSIDE CloudFormation by scripts/update-allowlist.sh, so a redeploy
  // of this stack never resets it to a stale value.
  homeIp: '/aio/home-ip',
} as const;

export class PersistentStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: PersistentStackProps) {
    super(scope, id, props);

    // ---------------------------------------------------------------- S3 backups
    const bucket = new s3.Bucket(this, 'BackupBucket', {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      // Retention: scripts/backup.sh overwrites ONE key (backups/latest.tar.gz) each run; versioning keeps
      // the history. Keep the current version plus the 1 newest previous version; older versions are
      // deleted once they are >= 1 day old (S3's minimum), so you hold at least 2 backups and a few
      // extra at most within the last day. No timestamped keys pile up, and the backup agent never
      // needs delete permission.
      lifecycleRules: [
        {
          id: 'keep-current-plus-one-previous',
          noncurrentVersionsToRetain: 1,
          noncurrentVersionExpiration: cdk.Duration.days(1),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(2),
          expiredObjectDeleteMarker: true,
        },
      ],
    });

    // ------------------------------------------------------------------ Route53
    // Delegated subdomain: add the NS records from the `NameServers` output at the parent domain's DNS
    // provider once. Kept in this persistent stack so nameservers never change.
    const zone = new route53.PublicHostedZone(this, 'Zone', {
      zoneName: props.domain,
      comment: 'AIO DR - delegated subdomain',
    });
    zone.applyRemovalPolicy(cdk.RemovalPolicy.RETAIN);

    // ---------------------------------------------------- IAM user for the PC agent
    // Used by the backup + allowlist timers on the PC (and your laptop, if needed).
    // Deliberately narrow: can write/read backups and update the home-IP parameter only.
    const agent = new iam.User(this, 'PcAgent', { userName: 'aio-pc-agent' });

    // Explicit minimal actions (the grantPut/grantRead helpers add retention, tagging, List*).
    agent.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:PutObject', 's3:GetObject'],
        resources: [bucket.arnForObjects('backups/*')],
      }),
    );
    agent.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [bucket.bucketArn],
        conditions: { StringLike: { 's3:prefix': ['backups/*'] } },
      }),
    );
    agent.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ssm:PutParameter', 'ssm:GetParameter'],
        resources: [this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: PARAM.homeIp.slice(1) })],
      }),
    );
    agent.addToPolicy(
      new iam.PolicyStatement({
        actions: ['ssm:GetParameter'],
        resources: [
          PARAM.bucket,
          PARAM.zoneId,
          PARAM.domain,
        ].map((p) => this.formatArn({ service: 'ssm', resource: 'parameter', resourceName: p.slice(1) })),
      }),
    );

    agent.addToPolicy(
      new iam.PolicyStatement({
        actions: ['cloudwatch:PutMetricData'],
        resources: ['*'], // PutMetricData does not support resource-level permissions; scoped by namespace:
        conditions: { StringEquals: { 'cloudwatch:namespace': 'AIO/DR' } },
      }),
    );

    // ------------------------------------------------------ "PC is down" alerts
    // scripts/heartbeat.sh (timer on the PC) puts Heartbeat and AppsHealthy metrics every 5 minutes;
    // scripts/backup.sh puts BackupSucceeded after each upload.
    // Alarm-only: nothing auto-deploys. Within the CloudWatch free tier (10 alarms / 10 metrics).
    const topic = new sns.Topic(this, 'AlertTopic', { displayName: 'AIO DR alerts' });
    topic.addSubscription(new subs.EmailSubscription(props.alertEmail));
    const notify = new cwActions.SnsAction(topic);

    const heartbeat = new cw.Metric({
      namespace: 'AIO/DR',
      metricName: 'Heartbeat',
      statistic: 'Sum',
      period: cdk.Duration.minutes(5),
    });
    const pcSilent = new cw.Alarm(this, 'PcSilent', {
      alarmName: 'aio-pc-silent',
      alarmDescription:
        'No heartbeat from the PC for ~20 min: PC, power or network is down. Deploy the recovery stack (s3://<bucket>/dr/RUNBOOK.txt).',
      metric: heartbeat,
      threshold: 1,
      comparisonOperator: cw.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 4,
      datapointsToAlarm: 4,
      treatMissingData: cw.TreatMissingData.BREACHING,
    });
    pcSilent.addAlarmAction(notify);
    pcSilent.addOkAction(notify);

    const appsHealthy = new cw.Metric({
      namespace: 'AIO/DR',
      metricName: 'AppsHealthy',
      statistic: 'Minimum',
      period: cdk.Duration.minutes(5),
    });
    const appsDown = new cw.Alarm(this, 'AppsDown', {
      alarmName: 'aio-apps-unhealthy',
      alarmDescription: 'PC is up but AIOStreams/AIOMetadata are not answering locally for ~15 min.',
      metric: appsHealthy,
      threshold: 1,
      comparisonOperator: cw.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 3,
      datapointsToAlarm: 3,
      treatMissingData: cw.TreatMissingData.NOT_BREACHING, // PcSilent covers a missing heartbeat
    });
    appsDown.addAlarmAction(notify);
    appsDown.addOkAction(notify);

    // scripts/backup.sh puts BackupSucceeded=1 after each upload (every 6h). 13 consecutive empty hours
    // = two missed runs in a row. Also fires while the PC is down (PcSilent explains why).
    const backupsOk = new cw.Metric({
      namespace: 'AIO/DR',
      metricName: 'BackupSucceeded',
      statistic: 'Sum',
      period: cdk.Duration.hours(1),
    });
    const backupStale = new cw.Alarm(this, 'BackupStale', {
      alarmName: 'aio-backup-stale',
      alarmDescription:
        'No successful backup for 13h (backups run every 6h). On the PC: journalctl --user -u aio-backup',
      metric: backupsOk,
      threshold: 1,
      comparisonOperator: cw.ComparisonOperator.LESS_THAN_THRESHOLD,
      evaluationPeriods: 13,
      datapointsToAlarm: 13,
      treatMissingData: cw.TreatMissingData.BREACHING,
    });
    backupStale.addAlarmAction(notify);
    backupStale.addOkAction(notify);

    // ------------------------------------------------- Discovery parameters (SSM)
    new ssm.StringParameter(this, 'BucketParam', { parameterName: PARAM.bucket, stringValue: bucket.bucketName });
    new ssm.StringParameter(this, 'ZoneParam', { parameterName: PARAM.zoneId, stringValue: zone.hostedZoneId });
    new ssm.StringParameter(this, 'DomainParam', { parameterName: PARAM.domain, stringValue: props.domain });

    // ------------------------------------------------------------------ Outputs
    new cdk.CfnOutput(this, 'BackupBucketName', { value: bucket.bucketName });
    new cdk.CfnOutput(this, 'HostedZoneId', { value: zone.hostedZoneId });
    new cdk.CfnOutput(this, 'NameServers', {
      description: `Add these as NS records for host "${props.domain.split('.')[0]}" at the parent domain's DNS provider`,
      value: cdk.Fn.join(' , ', zone.hostedZoneNameServers!),
    });
    new cdk.CfnOutput(this, 'PcAgentUser', { value: agent.userName });
    new cdk.CfnOutput(this, 'AlertTopicArn', { value: topic.topicArn });
  }
}
