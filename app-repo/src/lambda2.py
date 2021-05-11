def handler(event,context):
    return {
        'body': 'call {0}'.format(event['requestContext']['identity']['sourceIp']),
        'headers': {
            'Content-Type': 'text/plain'
        },
        'statusCode': 200
    }