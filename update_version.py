#import uuid


with open('Project.toml', 'r') as f:
    lines = list(f.readlines())
#uuid_line = lines[1]
version_line = lines[2]

#new_uuid = uuid.uuid4()
#new_uuid_line = 'uuid = "{}"\n'.format(str(new_uuid))

version = version_line.split('"')[1]
version = [int(x) for x in version.split('.')]
version[-1] += 1
version = '.'.join([str(x) for x in version])
new_version_line = 'version = "{}"\n'.format(version)

with open('Project.toml', 'w') as f:
    f.write(lines[0])
    f.write(lines[1])
    #f.write(new_uuid_line)
    f.write(new_version_line)
    f.write(''.join(lines[3:]))

