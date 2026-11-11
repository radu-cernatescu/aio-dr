import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { PARAM } from './persistent-stack';

export interface RecoveryStackProps extends cdk.StackProps {
  /** Delegated zone, e.g. aio.example.com */
  readonly domain: string;
  /** Public hostnames (must live inside `domain`). */
  readonly streamsHost: string;
  readonly metaHost: string;
  readonly instanceType: string;
}

/**
 * On-demand (cold standby) stack: restores the latest S3 backup onto a fresh EC2 instance behind
 * Caddy (Let's Encrypt via Route53 DNS-01). Removing the stack removes everything except the
 * persistent stack (bucket, zone, IAM).
 *
 * The synthesized template is STANDALONE (no CDK assets) and is published to S3 by
 * scripts/publish-template.sh, so it can be deployed from the console or CLI without this repo.
 * The allowlist is a CloudFormation parameter: it defaults to SSM /aio/home-ip (resolved at deploy
 * time) and takes one optional extra CIDR (e.g. the network you are on during an outage).
 */
export class RecoveryStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: RecoveryStackProps) {
    super(scope, id, props);

    // Discovery values written by AioPersistent (resolved by CloudFormation at deploy time).
    const bucketName = ssm.StringParameter.valueForStringParameter(this, PARAM.bucket);
    const zoneId = ssm.StringParameter.valueForStringParameter(this, PARAM.zoneId);
    const zone = route53.HostedZone.fromHostedZoneAttributes(this, 'Zone', {
      hostedZoneId: zoneId,
      zoneName: props.domain,
    });

    // ------------------------------------------------------------------ Network
    // Public subnet only, one AZ, no NAT gateway (a NAT would cost ~$37/month).
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });

    // Allowlist as parameters. Minimum prefix /16 blocks 0.0.0.0/0 and other overly broad ranges.
    const CIDR_PATTERN = '(\\d{1,3}\\.){3}\\d{1,3}/(1[6-9]|2\\d|3[0-2])';
    // SSM-typed parameter: its value is an SSM *key name*, resolved to the stored CIDR at deploy time.
    // No AllowedPattern here (CloudFormation would match it against the key name). The stored value is
    // validated as an IPv4 /32 by scripts/update-allowlist.sh before it is written. To allow another
    // network, use ExtraCidr.
    const allowedCidr = new cdk.CfnParameter(this, 'AllowedCidr', {
      type: 'AWS::SSM::Parameter::Value<String>',
      default: PARAM.homeIp,
      description: `SSM parameter holding the primary allowlisted CIDR (default ${PARAM.homeIp}, kept current by the PC). Leave as is.`,
    });
    const extraCidr = new cdk.CfnParameter(this, 'ExtraCidr', {
      type: 'String',
      default: '',
      description: 'Optional second allowlisted CIDR, e.g. the network you are on right now (leave empty for none).',
      allowedPattern: `^$|^${CIDR_PATTERN}$`,
      constraintDescription: 'Empty, or an IPv4 CIDR no broader than /16, e.g. 203.0.113.7/32',
    });
    const hasExtra = new cdk.CfnCondition(this, 'HasExtraCidr', {
      expression: cdk.Fn.conditionNot(cdk.Fn.conditionEquals(extraCidr.valueAsString, '')),
    });

    const sg = new ec2.SecurityGroup(this, 'Sg', {
      vpc,
      description: 'AIO DR: 443 from allowlisted IPs only',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.ipv4(allowedCidr.valueAsString), ec2.Port.tcp(443), 'allowlist: primary');
    const extraRule = new ec2.CfnSecurityGroupIngress(this, 'ExtraIngress', {
      groupId: sg.securityGroupId,
      ipProtocol: 'tcp',
      fromPort: 443,
      toPort: 443,
      cidrIp: extraCidr.valueAsString,
      description: 'allowlist: extra',
    });
    extraRule.cfnOptions.condition = hasExtra;

    // --------------------------------------------------------------------- Role
    const role = new iam.Role(this, 'Role', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')],
    });
    // Read the backups.
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:GetObject'],
        // backups, plus pre-staged third-party artifacts (compose binary, caddy image)
        resources: [
          `arn:${this.partition}:s3:::${bucketName}/backups/*`,
          `arn:${this.partition}:s3:::${bucketName}/dr/artifacts/*`,
        ],
      }),
    );
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [`arn:${this.partition}:s3:::${bucketName}`],
        conditions: { StringLike: { 's3:prefix': ['backups/*', 'dr/artifacts/*'] } },
      }),
    );
    // Caddy DNS-01: TXT records in the delegated zone only.
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['route53:ChangeResourceRecordSets', 'route53:ListResourceRecordSets'],
        resources: [zone.hostedZoneArn],
      }),
    );
    role.addToPolicy(new iam.PolicyStatement({ actions: ['route53:GetChange'], resources: [`arn:${this.partition}:route53:::change/*`] }));
    role.addToPolicy(new iam.PolicyStatement({ actions: ['route53:ListHostedZonesByName'], resources: ['*'] }));
    // cfn-signal at the end of bootstrap.
    role.addToPolicy(
      new iam.PolicyStatement({
        actions: ['cloudformation:SignalResource'],
        resources: [`arn:${this.partition}:cloudformation:${this.region}:${this.account}:stack/${this.stackName}/*`],
      }),
    );

    // ----------------------------------------------------------------- Instance
    const recoveryFile = (f: string) => fs.readFileSync(path.join(__dirname, '..', 'recovery', f), 'utf8');
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      'set -euxo pipefail',
      'exec > >(tee -a /var/log/aio-bootstrap.log) 2>&1',
      `export BACKUP_BUCKET="${bucketName}"`,
      `export ZONE_ID="${zoneId}"`,
      `export STREAMS_HOST="${props.streamsHost}"`,
      `export META_HOST="${props.metaHost}"`,
      'set -a', // versions.env: KEY=value lines, exported
      recoveryFile('versions.env'),
      'set +a',
      // Fallback Caddy build recipe (used only if the prebuilt image is missing from S3). Same file
      // scripts/publish-template.sh builds the staged image from, so the two cannot drift.
      'mkdir -p /opt/aio/caddy',
      `cat > /opt/aio/caddy/Dockerfile <<'DOCKERFILE'\n${recoveryFile('caddy/Dockerfile').trimEnd()}\nDOCKERFILE`,
      recoveryFile('bootstrap.sh'),
    );

    const instance = new ec2.Instance(this, 'Instance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType(props.instanceType),
      // x86_64: the images are amd64-only as far as verified.
      machineImage: ec2.MachineImage.latestAmazonLinux2023({ cpuType: ec2.AmazonLinuxCpuType.X86_64 }),
      securityGroup: sg,
      role,
      associatePublicIpAddress: true,
      userData,
      userDataCausesReplacement: true,
      resourceSignalTimeout: cdk.Duration.minutes(20),
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(16, { volumeType: ec2.EbsDeviceVolumeType.GP3, encrypted: true }),
        },
      ],
    });
    userData.addSignalOnExitCommand(instance);
    // IMDSv2 required + hop limit pinned to 1, via a launch template (CfnInstance has no metadata
    // options). Hop limit 1 means containers on Docker's bridge network cannot reach the instance
    // role; Caddy runs on the host network so it still can.
    const imdsTemplate = new ec2.LaunchTemplate(this, 'ImdsTemplate', {
      httpEndpoint: true,
      httpTokens: ec2.LaunchTemplateHttpTokens.REQUIRED,
      httpPutResponseHopLimit: 1,
    });
    (instance.node.defaultChild as ec2.CfnInstance).launchTemplate = {
      launchTemplateId: imdsTemplate.launchTemplateId,
      version: imdsTemplate.latestVersionNumber,
    };

    // ---------------------------------------------------------------------- DNS
    // Managed by CloudFormation so `cdk destroy` removes them and a new deploy points at the new IP.
    for (const [id, host] of [
      ['Streams', props.streamsHost],
      ['Meta', props.metaHost],
    ]) {
      new route53.ARecord(this, `A${id}`, {
        zone,
        recordName: host,
        target: route53.RecordTarget.fromIpAddresses(instance.instancePublicIp),
        ttl: cdk.Duration.seconds(60),
      });
    }

    new cdk.CfnOutput(this, 'StreamsUrl', { value: `https://${props.streamsHost}` });
    new cdk.CfnOutput(this, 'MetaUrl', { value: `https://${props.metaHost}` });
    new cdk.CfnOutput(this, 'InstanceId', { value: instance.instanceId });
    new cdk.CfnOutput(this, 'AllowedCidrs', {
      value: cdk.Fn.conditionIf(hasExtra.logicalId, cdk.Fn.join(', ', [allowedCidr.valueAsString, extraCidr.valueAsString]), allowedCidr.valueAsString).toString(),
    });
    new cdk.CfnOutput(this, 'ShellCommand', { value: `aws ssm start-session --target ${instance.instanceId} --region ${this.region}` });
  }
}
