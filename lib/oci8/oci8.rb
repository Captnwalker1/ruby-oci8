# oci8.rb -- implements OCI8 and OCI8::Cursor
#
# Copyright (C) 2002-2012 KUBO Takehiro <kubo@jiubao.org>
#
# Original Copyright is:
#   Oracle module for Ruby
#   1998-2000 by yoshidam
#

require 'date'
require 'yaml'

# A connection to a Oracle database server.
#
# example:
#   # output the emp table's content as CSV format.
#   conn = OCI8.new(username, password)
#   conn.exec('select * from emp') do |row|
#     puts row.join(',')
#   end
#
#   # execute PL/SQL block with bind variables.
#   conn = OCI8.new(username, password)
#   conn.exec('BEGIN procedure_name(:1, :2); END;',
#              value_for_the_first_parameter,
#              value_for_the_second_parameter)
class OCI8

  # call-seq:
  #   new(username, password, dbname = nil, privilege = nil)
  #
  # Connects to an Oracle database server by +username+ and +password+
  # at +dbname+ as +privilege+.
  #
  # === connecting to the local server
  #
  # Set +username+ and +password+ or pass "username/password" as a
  # single argument.
  #
  #   OCI8.new('scott', 'tiger')
  # or
  #   OCI8.new('scott/tiger')
  #
  # === connecting to a remote server
  #
  # Set +username+, +password+ and +dbname+ or pass
  # "username/password@dbname" as a single argument.
  #
  #   OCI8.new('scott', 'tiger', 'orcl.world')
  # or
  #   OCI8.new('scott/tiger@orcl.world')
  #
  # The +dbname+ is a net service name or an easy connectection
  # identifier. The former is a name listed in the file tnsnames.ora.
  # Ask to your DBA if you don't know what it is. The latter has the
  # syntax as "//host:port/service_name".
  #
  #   OCI8.new('scott', 'tiger', '//remote-host:1521/XE')
  # or
  #   OCI8.new('scott/tiger@//remote-host:1521/XE')
  #
  # === connecting as a privileged user
  #
  # Set :SYSDBA or :SYSOPER to +privilege+, otherwise
  # "username/password as sysdba" or "username/password as sysoper"
  # as a single argument.
  #
  #   OCI8.new('sys', 'change_on_install', nil, :SYSDBA)
  # or
  #   OCI8.new('sys/change_on_install as sysdba')
  #
  # === external OS authentication
  #
  # Set nil to +username+ and +password+, or "/" as a single argument.
  #
  #   OCI8.new(nil, nil)
  # or
  #   OCI8.new('/')
  #
  # To connect to a remote host:
  #
  #   OCI8.new(nil, nil, 'dbname')
  # or
  #   OCI8.new('/@dbname')
  #
  # === proxy authentication
  #
  # Enclose end user's username with square brackets and add it at the
  # end of proxy user's username.
  #
  #   OCI8.new('proxy_user_name[end_user_name]', 'proxy_password')
  # or
  #   OCI8.new('proxy_user_name[end_user_name]/proxy_password')
  #
  def initialize(*args)
    if args.length == 1
      username, password, dbname, mode = parse_connect_string(args[0])
    else
      username, password, dbname, mode = args
    end

    if username.nil? and password.nil?
      cred = OCI_CRED_EXT
    end
    case mode
    when :SYSDBA
      mode = OCI_SYSDBA
    when :SYSOPER
      mode = OCI_SYSOPER
    when :SYSASM
      if OCI8.oracle_client_version < OCI8::ORAVER_11_1
        raise "SYSASM is not supported on Oracle version #{OCI8.oracle_client_version}"
      end
      mode = OCI_SYSASM
    when nil
      # do nothing
    else
      raise "unknown privilege type #{mode}"
    end

    stmt_cache_size = OCI8.properties[:statement_cache_size]
    stmt_cache_size = nil if stmt_cache_size == 0

    if mode.nil? and cred.nil?
      # logon by the OCI function OCILogon2().
      logon2_mode = 0
      if dbname.is_a? OCI8::ConnectionPool
        @pool = dbname # to prevent GC from freeing the connection pool.
        dbname = dbname.send(:pool_name)
        logon2_mode |= 0x0200 # OCI_LOGON2_CPOOL
      end
      if stmt_cache_size
        # enable statement caching
        logon2_mode |= 0x0004 # OCI_LOGON2_STMTCACHE
      end

      logon2(username, password, dbname, logon2_mode)

      if stmt_cache_size
        # set statement cache size
        attr_set_ub4(176, stmt_cache_size) # 176: OCI_ATTR_STMTCACHESIZE
      end
    else
      # logon by the OCI function OCISessionBegin().
      attach_mode = 0
      if dbname.is_a? OCI8::ConnectionPool
        @pool = dbname # to prevent GC from freeing the connection pool.
        dbname = dbname.send(:pool_name)
        attach_mode |= 0x0200 # OCI_CPOOL
      end
      if stmt_cache_size
        # enable statement caching
        attach_mode |= 0x0004 # OCI_STMT_CACHE
      end

      allocate_handles()
      @session_handle.send(:attr_set_string, OCI_ATTR_USERNAME, username) if username
      @session_handle.send(:attr_set_string, OCI_ATTR_PASSWORD, password) if password
      server_attach(dbname, attach_mode)
      session_begin(cred ? cred : OCI_CRED_RDBMS, mode ? mode : OCI_DEFAULT)

      if stmt_cache_size
        # set statement cache size
        attr_set_ub4(176, stmt_cache_size) # 176: OCI_ATTR_STMTCACHESIZE
      end
    end

    @prefetch_rows = nil
    @username = nil
  end

  # call-seq:
  #   parse(sql_text) -> an OCI8::Cursor
  #
  # Returns a prepared SQL handle.
  def parse(sql)
    @last_error = nil
    parse_internal(sql)
  end

  # same with OCI8#parse except that this doesn't reset OCI8#last_error.
  def parse_internal(sql)
    cursor = OCI8::Cursor.new(self, sql)
    cursor.prefetch_rows = @prefetch_rows if @prefetch_rows
    cursor
  end

  # Executes the sql statement. The type of return value depends on
  # the type of sql statement: select; insert, update and delete;
  # create, alter and drop; and PL/SQL.
  #
  # When bindvars are specified, they are bound as bind variables
  # before execution.
  #
  # == select statements without block
  # It returns the instance of OCI8::Cursor.
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   cursor = conn.exec('SELECT * FROM emp')
  #   while r = cursor.fetch()
  #     puts r.join(',')
  #   end
  #   cursor.close
  #   conn.logoff
  #
  # == select statements with a block
  # It acts as iterator and returns the processed row counts. Fetched
  # data is passed to the block as array. NULL value becomes nil in ruby.
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   num_rows = conn.exec('SELECT * FROM emp') do |r|
  #     puts r.join(',')
  #   end
  #   puts num_rows.to_s + ' rows were processed.'
  #   conn.logoff
  #
  # == PL/SQL block (ruby-oci8 1.0)
  # It returns the array of bind variables' values.
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   conn.exec("BEGIN :str := TO_CHAR(:num, 'FM0999'); END;", 'ABCD', 123)
  #   # => ["0123", 123]
  #   conn.logoff
  #
  # Above example uses two bind variables which names are :str
  # and :num. These initial values are "the string whose width
  # is 4 and whose value is 'ABCD'" and "the number whose value is
  # 123". This method returns the array of these bind variables,
  # which may modified by PL/SQL statement. The order of array is
  # same with that of bind variables.
  #
  # If a block is given, it is ignored.
  #
  # == PL/SQL block (ruby-oci8 2.0)
  # It returns the number of processed rows.
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   conn.exec("BEGIN :str := TO_CHAR(:num, 'FM0999'); END;", 'ABCD', 123)
  #   # => 1
  #   conn.logoff
  #
  # If a block is given, the bind variables' values are passed to the block after
  # executed.
  #
  #   conn = OCI8.new('scott', 'tiger')
  #   conn.exec("BEGIN :str := TO_CHAR(:num, 'FM0999'); END;", 'ABCD', 123) do |str, num|
  #     puts str # => '0123'
  #     puts num # => 123
  #   end
  #   conn.logoff
  #
  # FYI, the following code do same on ruby-oci8 1.0 and ruby-oci8 2.0.
  #   conn.exec(sql, *bindvars) { |*outvars| outvars }
  #
  # == Other SQL statements
  # It returns the number of processed rows.
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   num_rows = conn.exec('UPDATE emp SET sal = sal * 1.1')
  #   puts num_rows.to_s + ' rows were updated.'
  #   conn.logoff
  #
  # example:
  #   conn = OCI8.new('scott', 'tiger')
  #   conn.exec('CREATE TABLE test (col1 CHAR(6))') # => 0
  #   conn.logoff
  #
  def exec(sql, *bindvars, &block)
    @last_error = nil
    exec_internal(sql, *bindvars, &block)
  end

  # same with OCI8#exec except that this doesn't reset OCI8#last_error.
  def exec_internal(sql, *bindvars)
    begin
      cursor = parse(sql)
      ret = cursor.exec(*bindvars)
      case cursor.type
      when :select_stmt
        if block_given?
          cursor.fetch { |row| yield(row) }   # for each row
          ret = cursor.row_count()
        else
          ret = cursor
          cursor = nil # unset cursor to skip cursor.close in ensure block
          ret
        end
      when :begin_stmt, :declare_stmt # PL/SQL block
        if block_given?
          ary = []
          cursor.keys.sort.each do |key|
            ary << cursor[key]
          end
          yield(*ary)
        else
          ret
        end
      else
        ret # number of rows processed
      end
    ensure
      cursor.nil? || cursor.close
    end
  end # exec

  # :call-seq:
  #   select_one(sql, *bindvars) -> first_one_row
  #
  def select_one(sql, *bindvars)
    cursor = self.parse(sql)
    begin
      cursor.exec(*bindvars)
      row = cursor.fetch
    ensure
      cursor.close
    end
    return row
  end

  def username
    @username || begin
      exec('select user from dual') do |row|
        @username = row[0]
      end
      @username
    end
  end

  def inspect
    "#<OCI8:#{username}>"
  end

  # :call-seq:
  #   oracle_server_version -> oraver
  #
  # Returns an OCI8::OracleVersion of the Oracle server version.
  #
  # See also: OCI8.oracle_client_version
  def oracle_server_version
    unless defined? @oracle_server_version
      if vernum = oracle_server_vernum
        # If the Oracle client is Oracle 9i or upper,
        # get the server version from the OCI function OCIServerRelease.
        @oracle_server_version = OCI8::OracleVersion.new(vernum)
      else
        # Otherwise, get it from v$version.
        self.exec('select banner from v$version') do |row|
          if /^Oracle.*?(\d+\.\d+\.\d+\.\d+\.\d+)/ =~ row[0]
            @oracle_server_version = OCI8::OracleVersion.new($1)
            break
          end
        end
      end
    end
    @oracle_server_version
  end

  # :call-seq:
  #   database_charset_name -> string
  #
  # (new in 2.1.0)
  #
  # Returns the database character set name.
  def database_charset_name
    charset_id2name(@server_handle.send(:attr_get_ub2, OCI_ATTR_CHARSET_ID))
  end

  # :call-seq:
  #   OCI8.client_charset_name -> string
  #
  # (new in 2.1.0)
  #
  # Returns the client character set name.
  def self.client_charset_name
    @@client_charset_name
  end

  # The instance of this class corresponds to cursor in the term of
  # Oracle, which corresponds to java.sql.Statement of JDBC and statement
  # handle $sth of Perl/DBI.
  #
  # Don't create the instance by calling 'new' method. Please create it by
  # calling OCI8#exec or OCI8#parse.
  class Cursor

    # explicitly indicate the date type of fetched value. run this
    # method within parse and exec. pos starts from 1. lentgh is used
    # when type is String.
    # 
    # example:
    #   cursor = conn.parse("SELECT ename, hiredate FROM emp")
    #   cursor.define(1, String, 20) # fetch the first column as String.
    #   cursor.define(2, Time)       # fetch the second column as Time.
    #   cursor.exec()
    def define(pos, type, length = nil)
      __define(pos, make_bind_object(:type => type, :length => length))
      self
    end # define

    # Binds variables explicitly.
    # 
    # When key is number, it binds by position, which starts from 1.
    # When key is string, it binds by the name of placeholder.
    #
    # example:
    #   cursor = conn.parse("SELECT * FROM emp WHERE ename = :ename")
    #   cursor.bind_param(1, 'SMITH') # bind by position
    #     ...or...
    #   cursor.bind_param(':ename', 'SMITH') # bind by name
    #
    # To bind as number, Fixnum and Float are available, but Bignum is
    # not supported. If its initial value is NULL, please set nil to 
    # +type+ and Fixnum or Float to +val+.
    #
    # example:
    #   cursor.bind_param(1, 1234) # bind as Fixnum, Initial value is 1234.
    #   cursor.bind_param(1, 1234.0) # bind as Float, Initial value is 1234.0.
    #   cursor.bind_param(1, nil, Fixnum) # bind as Fixnum, Initial value is NULL.
    #   cursor.bind_param(1, nil, Float) # bind as Float, Initial value is NULL.
    #
    # In case of binding a string, set the string itself to
    # +val+. When the bind variable is used as output, set the
    # string whose length is enough to store or set the length.
    #
    # example:
    #   cursor = conn.parse("BEGIN :out := :in || '_OUT'; END;")
    #   cursor.bind_param(':in', 'DATA') # bind as String with width 4.
    #   cursor.bind_param(':out', nil, String, 7) # bind as String with width 7.
    #   cursor.exec()
    #   p cursor[':out'] # => 'DATA_OU'
    #   # Though the length of :out is 8 bytes in PL/SQL block, it is
    #   # bound as 7 bytes. So result is cut off at 7 byte.
    #
    # In case of binding a string as RAW, set OCI::RAW to +type+.
    #
    # example:
    #   cursor = conn.parse("INSERT INTO raw_table(raw_column) VALUE (:1)")
    #   cursor.bind_param(1, 'RAW_STRING', OCI8::RAW)
    #   cursor.exec()
    #   cursor.close()
    def bind_param(key, param, type = nil, length = nil)
      case param
      when Hash
      when Class
        param = {:value => nil,   :type => param, :length => length}
      else
        param = {:value => param, :type => type,  :length => length}
      end
      __bind(key, make_bind_object(param))
      self
    end # bind_param

    # Executes the SQL statement assigned the cursor. The type of
    # return value depends on the type of sql statement: select;
    # insert, update and delete; create, alter, drop and PL/SQL.
    #
    # In case of select statement, it returns the number of the
    # select-list.
    #
    # In case of insert, update or delete statement, it returns the
    # number of processed rows.
    #
    # In case of create, alter, drop and PL/SQL statement, it returns
    # true. In contrast with OCI8#exec, it returns true even
    # though PL/SQL. Use OCI8::Cursor#[] explicitly to get bind
    # variables.
    def exec(*bindvars)
      bind_params(*bindvars)
      __execute(nil) # Pass a nil to specify the statement isn't an Array DML
      case type
      when :select_stmt
        define_columns()
      else
        row_count
      end
    end # exec

    # Set the maximum array size for bind_param_array
    #
    # All the binds will be clean from cursor if instance variable max_array_size is set before
    #
    # Instance variable actual_array_size holds the size of the arrays users actually binds through bind_param_array
    #  all the binding arrays are required to be the same size
    def max_array_size=(size)
      raise "expect positive number for max_array_size." if size.nil? && size <=0
      __clearBinds if !@max_array_size.nil?
      @max_array_size = size
      @actual_array_size = nil
    end # max_array_size=

    # Bind array explicitly
    #
    # When key is number, it binds by position, which starts from 1.
    # When key is string, it binds by the name of placeholder.
    # 
    # The max_array_size should be set before calling bind_param_array
    #
    # example:
    #   cursor = conn.parse("INSERT INTO test_table VALUES (:str)")
    #   cursor.max_array_size = 3
    #   cursor.bind_param_array(1, ['happy', 'new', 'year'], String, 30)
    #   cursor.exec_array
    def bind_param_array(key, var_array, type = nil, max_item_length = nil)
      raise "please call max_array_size= first." if @max_array_size.nil?
      raise "expect array as input param for bind_param_array." if !var_array.nil? && !(var_array.is_a? Array) 
      raise "the size of var_array should not be greater than max_array_size." if !var_array.nil? && var_array.size > @max_array_size

      if var_array.nil? 
        raise "all binding arrays should be the same size." unless @actual_array_size.nil? || @actual_array_size == 0
        @actual_array_size = 0
      else
        raise "all binding arrays should be the same size." unless @actual_array_size.nil? || var_array.size == @actual_array_size
        @actual_array_size = var_array.size if @actual_array_size.nil?
      end
      
      param = {:value => var_array, :type => type, :length => max_item_length, :max_array_size => @max_array_size}
      first_non_nil_elem = var_array.nil? ? nil : var_array.find{|x| x!= nil}
      
      if type.nil?
        if first_non_nil_elem.nil?
          raise "bind type is not given."
        else
          type = first_non_nil_elem.class
        end
      end
      
      bindclass = OCI8::BindType::Mapping[type]
      if bindclass.nil? and type.is_a? Class
        bindclass = OCI8::BindType::Mapping[type.to_s]
        OCI8::BindType::Mapping[type] = bindclass if bindclass
      end
      raise "unsupported dataType: #{type}" if bindclass.nil?
      bindobj = bindclass.create(@con, var_array, param, @max_array_size)
      __bind(key, bindobj)
      self
    end # bind_param_array

    # Executes the SQL statement assigned the cursor with array binding
    def exec_array
      raise "please call max_array_size= first." if @max_array_size.nil?

      if !@actual_array_size.nil? && @actual_array_size > 0
        __execute(@actual_array_size)
      else
        raise "please set non-nil values to array binding parameters"
      end

      case type
      when :update_stmt, :delete_stmt, :insert_stmt
        row_count
      else
        true
      end
    end # exec_array

    # Gets the names of select-list as array. Please use this
    # method after exec.
    def get_col_names
      @names ||= @column_metadata.collect { |md| md.name }
    end # get_col_names

    # call-seq:
    #   column_metadata -> column information
    #
    # (new in 1.0.0 and 2.0)
    #
    # Gets an array of OCI8::Metadata::Column of a select statement.
    #
    # example:
    #   cursor = conn.exec('select * from tab')
    #   puts ' Name                                      Type'
    #   puts ' ----------------------------------------- ----------------------------'
    #   cursor.column_metadata.each do |colinfo|
    #     puts format(' %-41s %s',
    #                 colinfo.name,
    #                 colinfo.type_string)
    #   end
    def column_metadata
      @column_metadata
    end

    # call-seq:
    #   fetch_hash
    #
    # get fetched data as a Hash. The hash keys are column names.
    # If a block is given, acts as an iterator.
    def fetch_hash
      if iterator?
        while ret = fetch_a_hash_row()
          yield(ret)
        end
      else
        fetch_a_hash_row
      end
    end # fetch_hash

    # close the cursor.
    def close
      free()
      @names = nil
      @column_metadata = nil
    end # close

    # Returns the text of the SQL statement prepared in the cursor.
    #
    # @note
    #   When {http://docs.oracle.com/cd/E11882_01/server.112/e10729/ch7progrunicode.htm#CACHHIFE
    #   NCHAR String Literal Replacement} is turned on, it returns the modified SQL text,
    #   instead of the original SQL text.
    #
    # @example
    #    cursor = conn.parse("select * from country where country_code = 'ja'")
    #    cursor.statement # => "select * from country where country_code = 'ja'"
    #
    # @return [String]
    def statement
      # The magic number 144 is OCI_ATTR_STATEMENT.
      # See http://docs.oracle.com/cd/E11882_01/appdev.112/e10646/ociaahan.htm#sthref5503
      attr_get_string(144)
    end

    private

    def make_bind_object(param)
      case param
      when Hash
        key = param[:type]
        val = param[:value]
        max_array_size = param[:max_array_size]

        if key.nil?
          if val.nil?
            raise "bind type is not given."
          elsif val.is_a? OCI8::Object::Base
            key = :named_type
            param = @con.get_tdo_by_class(val.class)
          else
            key = val.class
          end
        elsif key.class == Class && key < OCI8::Object::Base
          param = @con.get_tdo_by_class(key)
          key = :named_type
        end
      when OCI8::Metadata::Base
        key = param.data_type
        case key
        when :named_type
          if param.type_name == 'XMLTYPE'
            key = :xmltype
          else
            param = @con.get_tdo_by_metadata(param.type_metadata)
          end
        end
      else
        raise "unknown param #{param.intern}"
      end

      bindclass = OCI8::BindType::Mapping[key]
      if bindclass.nil? and key.is_a? Class
        bindclass = OCI8::BindType::Mapping[key.to_s]
        OCI8::BindType::Mapping[key] = bindclass if bindclass
      end
      raise "unsupported datatype: #{key}" if bindclass.nil?
      bindclass.create(@con, val, param, max_array_size)
    end

    def define_columns
      num_cols = __param_count
      1.upto(num_cols) do |i|
        parm = __paramGet(i)
        define_one_column(i, parm) unless __defined?(i)
        @column_metadata[i - 1] = parm
      end
      num_cols
    end # define_columns

    def define_one_column(pos, param)
      __define(pos, make_bind_object(param))
    end # define_one_column

    def bind_params(*bindvars)
      bindvars.each_with_index do |val, i|
	if val.is_a? Array
	  bind_param(i + 1, val[0], val[1], val[2])
	else
	  bind_param(i + 1, val)
	end
      end
    end # bind_params

    def fetch_a_hash_row
      if rs = fetch()
        ret = {}
        get_col_names.each do |name|
          ret[name] = rs.shift
        end
        ret
      else 
        nil
      end
    end # fetch_a_hash_row

  end # OCI8::Cursor
end # OCI8

class OraDate

  # Returns a Time object which denotes self.
  def to_time
    begin
      Time.local(year, month, day, hour, minute, second)
    rescue ArgumentError
      msg = format("out of range of Time (expect between 1970-01-01 00:00:00 UTC and 2037-12-31 23:59:59, but %04d-%02d-%02d %02d:%02d:%02d %s)", year, month, day, hour, minute, second, Time.at(0).zone)
      raise RangeError.new(msg)
    end
  end

  # Returns a Date object which denotes self.
  def to_date
    Date.new(year, month, day)
  end

  if defined? DateTime # ruby 1.8.0 or upper

    # timezone offset of the time the command started
    # @private
    @@tz_offset = Time.now.utc_offset.to_r/86400

    # Returns a DateTime object which denotes self.
    #
    # Note that this is not daylight saving time aware.
    # The Time zone offset is that of the time the command started.
    def to_datetime
      DateTime.new(year, month, day, hour, minute, second, @@tz_offset)
    end
  end

  # @private
  def yaml_initialize(type, val)
    initialize(*val.split(/[ -\/:]+/).collect do |i| i.to_i end)
  end

  # @private
  def to_yaml(opts = {})
    YAML.quick_emit(object_id, opts) do |out|
      out.scalar(taguri, self.to_s, :plain)
    end
  end

  # @private
  def to_json(options=nil)
    to_datetime.to_json(options)
  end
end

class OraNumber

  if defined? Psych and YAML == Psych

    yaml_tag '!ruby/object:OraNumber'

    # @private
    def encode_with coder
      coder.scalar = self.to_s
    end

    # @private
    def init_with coder
      initialize(coder.scalar)
    end

  else

    # @private
    def yaml_initialize(type, val)
      initialize(val)
    end

    # @private
    def to_yaml(opts = {})
      YAML.quick_emit(object_id, opts) do |out|
        out.scalar(taguri, self.to_s, :plain)
      end
    end
  end

  # @private
  def to_json(options=nil)
    to_s
  end
end

class Numeric
  # Converts +self+ to {OraNumber}.
  def to_onum
    OraNumber.new(self)
  end
end

class String # :nodoc:

  # Converts +self+ to {OraNumber}.
  # Optional <i>fmt</i> and <i>nlsparam</i> is used as
  # {http://docs.oracle.com/cd/E11882_01/server.112/e17118/functions211.htm Oracle SQL function TO_NUMBER}
  # does.
  #
  # @example
  #   '123456.789'.to_onum # => #<OraNumber:123456.789>
  #   '123,456.789'.to_onum('999,999,999.999') # => #<OraNumber:123456.789>
  #   '123.456,789'.to_onum('999G999G999D999', "NLS_NUMERIC_CHARACTERS = ',.'") # => #<OraNumber:123456.789>
  #
  # @param [String] fmt
  # @param [String] nlsparam
  # @return [OraNumber]
  def to_onum(format = nil, nls_params = nil)
    OraNumber.new(self, format, nls_params)
  end
end
