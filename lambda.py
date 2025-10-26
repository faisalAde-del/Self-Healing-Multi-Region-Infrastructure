import boto3
import json
import os

def lambda_handler(event, context):
    """
    This function runs when CloudWatch says an instance is unhealthy.
    It launches a replacement instance in the backup region (us-west-2).
    """
    
    print("🚨 Received alert - starting healing process")
    print(f"Event: {json.dumps(event)}")
    
    # Get configuration from environment variables
    BACKUP_REGION = os.environ['BACKUP_REGION']
    BACKUP_AMI = os.environ['BACKUP_AMI']
    INSTANCE_TYPE = os.environ['INSTANCE_TYPE']
    SECURITY_GROUP_ID = os.environ['BACKUP_SECURITY_GROUP']
    SUBNET_ID = os.environ['BACKUP_SUBNET']
    
    # Connect to EC2 in the BACKUP region
    ec2_backup = boto3.client('ec2', region_name=BACKUP_REGION)
    sns_client = boto3.client('sns')
    
    try:
        # Parse the CloudWatch alarm message
        message = json.loads(event['Records'][0]['Sns']['Message'])
        alarm_name = message['AlarmName']
        instance_id = message['Trigger']['Dimensions'][0]['value']
        
        print(f"💔 Unhealthy instance: {instance_id}")
        print(f"🚀 Launching replacement in {BACKUP_REGION}")
        
        # Launch a NEW instance in the backup region
        response = ec2_backup.run_instances(
            ImageId=BACKUP_AMI,              # Operating system
            InstanceType=INSTANCE_TYPE,       # Size (t2.micro)
            MinCount=1,                       # Launch exactly 1
            MaxCount=1,
            SecurityGroupIds=[SECURITY_GROUP_ID],  # Firewall rules
            SubnetId=SUBNET_ID,               # Which network
            TagSpecifications=[{
                'ResourceType': 'instance',
                'Tags': [
                    {'Key': 'Name', 'Value': 'Backup-Healed-Instance'},
                    {'Key': 'HealedFrom', 'Value': instance_id},
                    {'Key': 'OriginalRegion', 'Value': 'us-east-1'}
                ]
            }],
            UserData="""#!/bin/bash
            # Install web server
            yum update -y
            yum install -y httpd
            
            # Create simple webpage
            echo "<h1>Backup Instance - System Healed!</h1>" > /var/www/html/index.html
            echo "<p>Original instance failed in us-east-1</p>" >> /var/www/html/index.html
            echo "<p>This backup instance launched in us-west-2</p>" >> /var/www/html/index.html
            
            # Start web server
            systemctl start httpd
            systemctl enable httpd
            """
        )
        
        # Get the new instance ID
        new_instance_id = response['Instances'][0]['InstanceId']
        new_instance_ip = response['Instances'][0].get('PublicIpAddress', 'Pending...')
        
        print(f"✅ Successfully launched: {new_instance_id}")
        
        # Send email notification
        sns_client.publish(
            TopicArn=os.environ['SNS_TOPIC_ARN'],
            Subject='🔧 Cross-Region Self-Healing Activated',
            Message=f"""
ALERT: Primary instance failed and was automatically healed!

Failed Instance:
- Instance ID: {instance_id}
- Region: us-east-1
- Alarm: {alarm_name}

Recovery Action Taken:
- Launched replacement in: {BACKUP_REGION}
- New Instance ID: {new_instance_id}
- Public IP: {new_instance_ip}

Status: System successfully healed across regions ✅

You can access the new instance at:
http://{new_instance_ip} (available in ~2 minutes)
            """
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Successfully healed to backup region',
                'failed_instance': instance_id,
                'new_instance': new_instance_id,
                'region': BACKUP_REGION
            })
        }
        
    except Exception as e:
        error_msg = f"❌ Error during healing: {str(e)}"
        print(error_msg)
        
        # Send error notification
        sns_client.publish(
            TopicArn=os.environ['SNS_TOPIC_ARN'],
            Subject='⚠️ Self-Healing Failed',
            Message=f"Failed to launch backup instance.\n\nError: {str(e)}"
        )
        
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }