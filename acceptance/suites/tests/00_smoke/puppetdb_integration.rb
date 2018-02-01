## Tests that PuppetDB can be integrated with Puppet Server in a simple
## monolithic install (i.e. PuppetDB on same node as Puppet Server).
##
## In this context 'integrated' just means that Puppet Server is able to
## communicate over HTTP/S with PuppetDB to send it information, such as
## agent run reports.
##
## This test validates communication is successful by querying the PuppetDB HTTP
## API and asserting that an updated factset, catalog and report from an agent
## run made it into PuppetDB. Additionally, the STDOUT of the agent run is
## tested for the presence of a Notify resource that was exported by another
## node.
##
## Finally, the output of the Puppet Server HTTP /status API is tested
## to ensure that metrics related to PuppetDB communication were recorded.
#

# We only run this test if we'll have puppetdb installed, which is gated in
# acceptance/suites/pre_suite/foss/95_install_pdb.rb using the same conditional
matching_puppetdb_platform = puppetdb_supported_platforms.select { |r| r =~ master.platform }
skip_test unless matching_puppetdb_platform.length > 0

require 'json'
require 'time'
require 'securerandom'

run_timestamp = nil
master_fqdn = on(master, '/opt/puppetlabs/bin/facter fqdn').stdout.chomp
random_string = SecureRandom.urlsafe_base64.freeze

step 'Configure site.pp for PuppetDB' do
  sitepp = '/etc/puppetlabs/code/environments/production/manifests/site.pp'
  create_remote_file(master, sitepp, <<EOM)
node 'resource-exporter.test' {
  @@notify{'#{random_string}': }
}

node '#{master_fqdn}' {
  Notify<<| title == '#{random_string}' |>>

  # Dummy query to record a hit for the PuppetDB query API to metrics.
  $_ = puppetdb_query(['from', 'nodes', ['extract', 'certname']])
}
EOM
  on(master, "chmod 644 #{sitepp}")

  teardown do
    on(master, "rm -f #{sitepp}")
  end
end

with_puppet_running_on(master, {}) do
  step 'Run agent to generate exported resources' do
    # This test compiles a catalog using a differnt certname so that
    # later runs can test collection.
    on(master, puppet('cert', 'generate', 'resource-exporter.test'))

    teardown do
      on(master, puppet('node', 'deactivate', 'resource-exporter.test'))
      on(master, puppet('cert', 'clean', 'resource-exporter.test'))
    end

    on(master, puppet_agent('--test', '--noop',
                            '--server', master_fqdn,
                            '--certname', 'resource-exporter.test'),
              :acceptable_exit_codes => [0,2])
  end

  step 'Run agent to trigger data submission to PuppetDB' do
    run_timestamp = Time.now.utc
    on(master, puppet_agent("--test --server #{master_fqdn}"), :acceptable_exit_codes => [0,2]) do
      assert_match(/Notice: #{random_string}/, stdout,
                  'Puppet run collects exported Notify')
    end
  end

  step 'Validate PuppetDB metrics captured by puppet-profiler service' do
    query = "curl -k https://localhost:8140/status/v1/services/puppet-profiler?level=debug"
    response = JSON.parse(on(master, query).stdout.chomp)
    pdb_metrics = response['status']['experimental']['puppetdb-metrics']

    # NOTE: If these tests fail, then likely someone changed a metric
    # name passed to Puppet::Util::Profiler.profile over in the Ruby
    # terminus code of the PuppetDB project without realizing that is a
    # breaking change to metrics critical for measuring compiler performance.
    %w[
      facts_encode command_submit_replace_facts
      catalog_munge command_submit_replace_catalog
      report_convert_to_wire_format_hash command_submit_store_report
      resource_search query
    ].each do |metric_name|
      metric_data = pdb_metrics.find({}) {|m| m['metric'] == metric_name }

      assert_operator(metric_data.fetch('count', 0), :>, 0,
                      "PuppetDB metrics recorded for: #{metric_name}")
    end
  end
end

step 'Validate server sent agent data to PuppetDB' do
  query = "curl http://localhost:8080/pdb/query/v4/nodes/#{master_fqdn}"
  response = JSON.parse(on(master, query).stdout.chomp)
  %w[facts_timestamp catalog_timestamp report_timestamp].each do |dataset|
    assert_operator(Time.iso8601(response[dataset]),
                    :>,
                    run_timestamp,
                   "#{dataset} updated in PuppetDB")
  end
end
