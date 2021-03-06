#     Copyright 2016 Netflix, Inc.
#
#     Licensed under the Apache License, Version 2.0 (the "License");
#     you may not use this file except in compliance with the License.
#     You may obtain a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.

require 'uri'
require 'net/http'
require 'json'
require 'rest-client'
require 'time'

class ScumblrTask::GithubAnalyzer < ScumblrTask::Base
  def self.task_type_name
    "Github Code Search"
  end

  def self.task_category
    "Security"
  end

  def self.description
    "Search github repos for specific values and create vulnerabilities for matches"
  end

  def self.config_options
    {:github_oauth_token =>{ name: "Github OAuth Token",
      description: "Setting this token provides the access needed to search Github organizations or repos",
      required: true
      }
    }
  end

  def self.options
    {
      :severity => {name: "Finding Severity",
                    description: "Set severity to either observation, high, medium, or low",
                    required: true,
                    type: :choice,
                    default: :observation,
                    choices: [:observation, :high, :medium, :low]},
      :key_suffix => {name: "Key Suffix",
                      description: "Provide a key suffix for testing out experimental regular expressions",
                      required: false,
                      type: :string
                      },
      :max_results => {name: "Limit search results",
                       description: "Limit search results.",
                       required: true,
                       default: "200",
                       type: :string},
      :search_terms => {name: "Search Strings",
                        description: "Provide newline delimited search strings",
                        required: false,
                        type: :text},
      :json_terms => {name: "JSON Array Strings URL",
                      description: "Provide URL for JSON array of search terms",
                      required: false,
                      type: :string},
      :user => {name: "Scope To User Or Organization",
                description: "Limit search to an Organization, User, or Repo Name.",
                required: false,
                type: :string},
      :repo => {name: "Scope To Repository",
                description: "Limit search to a specific repository.",
                required: false,
                type: :string},
      :scope => {name: "Search for file paths, file contents, or both",
                 description: "Search for file paths, file contents, or both.",
                 required: false,
                 type: :choice,
                 default: :both,
                 choices: [:file, :path, :both]},          
      :members => {name: "Scan Members Public Code of an Organization",
                   description: "Include members code of an organization.",
                   required: false,
                   type: :boolean}
    }
  end

  def rate_limit_sleep(remaining, reset)
    # This method sleeps until the rate limit resets
    if remaining.to_i <= 1
      time_to_sleep = (reset.to_i - Time.now.to_i)
      puts "Sleeping for #{time_to_sleep}"
      sleep (time_to_sleep + 1)
    end
  end

  def retry_after(reset)
    # This method sleeps until the rate limit resets
    puts "Sleeping for #{reset} due to 403"
    sleep (reset.to_i + 1)
  end

  def initialize(options={})
    super

    @github_oauth_token = @github_oauth_token.to_s.strip

    

    @search_scope = {}
    @results = []
    @terms = []
    @total_matches = 0

    if @options[:members] == "0"
      @options[:members] = false
    else
      @options[:members] = true
    end

    if(@options[:key_suffix].present?)
      @key_suffix = "_" + @options[:key_suffix].to_s.strip
      puts "A key suffix was provided: #{@key_suffix}."
    end

    @clone_schema =  @options[:clone_schema].to_s

    # Set the max results if specified, otherwise default to 200 results
    @options[:max_results] = @options[:max_results].to_i > 0 ? @options[:max_results].to_i : 200

    # Check to make sure either search terms or url was provided for search
    unless @options[:search_terms].present? or @options[:json_terms].present?
      create_event("No search terms provided.")
      raise 'No search terms provided.'
      return
    end

    # Check that they actually specified a repo or org.
    unless @options[:user].present? or @options[:repo].present?
      create_event("No user, org, or repo provided.")
      raise 'No user, org, or repo provided.'
      return
    end

    # If search terms are present, parse them out.
    if @options[:search_terms].present?
      @terms = @options[:search_terms].to_s.split(/\r?\n/).reject(&:empty?)
    end

    # If a URI is provided, try to parse the JSON array of terms and join
    # with any other search terms provided.
    if @options[:json_terms].present?
      begin
        @terms = @terms + JSON.parse(RestClient.get @options[:json_terms])
      rescue => e
        create_event("Unable to retrieve results for #{@options[:json_terms]}.\n\n. Exception: #{e.message}\n#{e.backtrace}")
        raise "Unable to retrieve results for #{json_terms}!"
      end
    end

    # Append any repos to the search scope
    if @options[:repo].present?
      @search_scope.merge!(@options[:repo] => "repo")
    end

    # If for some reason terms are still empty, raise an exception.
    if @terms.empty?
      create_event("Could not parse search terms.")
      raise 'Could not parse search terms.'
      return
    end

    # make sure search terms are unique
    @terms.uniq!

    # Check ratelimit for core lookups
    begin
      response = JSON.parse(RestClient.get "https://api.github.com/rate_limit?access_token=#{@github_oauth_token}")
      core_rate_limit = response["resources"]["core"]["remaining"].to_i

      # If we have hit the core limit, sleep
      rate_limit_sleep(core_rate_limit, response["resources"]["core"]["reset"])
    rescue => e
      create_event("Unable to retrieve rate limit from Github.\n\n. Exception: #{e.message}\n#{e.backtrace}")
      raise "Unable to retrieve rate limit for Github!"
    end

    # Determine if supplied input is org or not.
    begin
      while true
        if @options[:user].present? and core_rate_limit >= 0
          response = RestClient.get "https://api.github.com/users/#{@options[:user]}?access_token=#{@github_oauth_token}"
          json_response = JSON.parse(response)
          core_rate_limit -= 1
          @scope_type = json_response["type"]
          @search_scope[@options[:user]] = json_response["type"]
          rate_limit_sleep(core_rate_limit, response.headers[:x_ratelimit_reset])
          break
        else
          break
        end
      end
    rescue => e
      create_event("Unable to if suppiled input is an org.\n\n. Exception: #{e.message}\n#{e.backtrace}")
      raise "Unable to if suppiled input is an org"
    end

    # Determine how many pages of users we need to retrieve
    more_pages = false
    pages = 1
    begin
      while true
        if @options[:members] == true and @scope_type == "Organization" and core_rate_limit >= 0
          response = RestClient.get "https://api.github.com/orgs/#{@options[:user]}/members?access_token=#{@github_oauth_token}"
          json_response = JSON.parse(response)
          core_rate_limit -= 1
          # Check if has more than one page
          # If no link, then it's just one page it seems (API bug maybe?)
          unless response.headers[:link].present?
            more_pages = true
            json_response.each do | member_object |
              @search_scope.merge!(member_object["login"] => "user")
            end
            break
          end

          # If has more than one page, determine the number
          unless response.headers[:link].split(" ")[0].split("=").last.gsub!(/\W/,'') == 0
            more_pages = true
            pages = response.headers[:link].split(" ")[2].split("=").last.gsub!(/\W/,'')
          end

          # Sleep if we hit a ratelimit
          rate_limit_sleep(core_rate_limit, response.headers[:x_ratelimit_reset])
          break
        else
          break
        end
      end
    rescue => e
      create_event("Unable to if suppiled input is an org.\n\n. Exception: #{e.message}\n#{e.backtrace}")
      raise "Unable to if suppiled input is an org"
      return
    end

    # Append each user from each page to the searched_scope array
    if more_pages and @options[:members] == true
      begin
        1.upto(pages.to_i) do | page |
          if core_rate_limit >= 0
            response = RestClient.get "https://api.github.com/orgs/#{@options[:user]}/members?access_token=#{@github_oauth_token}&page=#{page}"
            json_response = JSON.parse(response)
            core_rate_limit -= 1

            # parse out each page here
            json_response.each do | member_object |
              @search_scope.merge!(member_object["login"] => "user")
            end
            # Sleep if we hit a rate limit
            rate_limit_sleep(core_rate_limit, response.headers[:x_ratelimit_reset])
          end
        end
      rescue => e
        create_event("Unable to if suppiled input is an org.\n\n. Exception: #{e.message}\n#{e.backtrace}")
        raise "Unable to if suppiled input is an org"
        return
      end
    end
  end

  def parse_search(response, json_response, user_type)
    # Parse out all of the important search metadata
    json_response["items"].each do | search |
      # For each hash in the json_response, parse out important fields
      search_metadata ||= {}
      #search_metadata[:github_analyzer] = true
      search_metadata[:github_analyzer] ||= {}
      search_metadata[:github_analyzer][:owner] = search["repository"]["owner"]["login"]
      search_metadata[:github_analyzer][:language] = search["repository"]["language"]
      search_metadata[:github_analyzer][:private] = search["repository"]["private"]
      search_metadata[:github_analyzer][:account_type] = user_type
      search_metadata[:github_analyzer][:git_clone_url] = "ssh://github.com/#{search["repository"]["full_name"]}.git"

      # Define data for vulnerability object
      search_metadata[:github_analyzer_vulnerabilities] ||= {}

      # Parse out text matches if there are any
      vulnerabilities = []

      if search.try(:[], "text_matches")
        # Keep track of the total # of matches
        # Iterate each finding and store in metadata
        # TODO: not sure we need bounds may be able to remove

        search["text_matches"].each do | snippit |
          vuln = Vulnerability.new

          if(@options[:key_suffix].present?)
            vuln.key_suffix = @options[:key_suffix]
          end
          vuln.source = "github"
          vuln.task_id = @options[:_self].id.to_s
          vuln.severity = @options[:severity]
          vuln.type = '"' + snippit["matches"].first["text"] + '"' + " - #{snippit["property"]} match"

          begin
            vuln.term = snippit["matches"].first["text"]
            vuln.score = search["score"]
            vuln.file_name = search["name"]
            vuln.url = search["html_url"]
            vuln.code_fragment = snippit["fragment"]
            vuln.match_location = snippit["property"]

            # Append the github vulns to the vulnerabilities array
            vulnerabilities << vuln
          rescue => e
            create_event("Unable to add metadata.\n\n. Exception: #{e.message}\n#{e.backtrace}", "Warn")
          end
        end
      else
        if(@options[:key_suffix].present?)
          vuln.key_suffix = @options[:key_suffix]
        end
        vuln.term = snippit["matches"].first["text"]
        vuln.source = "github"
        vuln.task_id = @options[:_self].id.to_s
        vuln.type = '"' + snippit["matches"].first["text"] + '"' + " - #{snippit["property"]} match"
        vuln.severity = @options[:severity]
        vuln.file_name = search["name"]
        vuln.url = search["html_url"]
        vulnerabilities << vuln
      end

      res = Result.where(url: search["repository"]["html_url"]).first

      if res.present?
        res.update_vulnerabilities(vulnerabilities)
        res.metadata.merge!({"github_analyzer" => search_metadata[:github_analyzer]})
        res.save!
        @results << res
        # Do not create new result simply append vulns to results
      else
        github_result = Result.new(url: search["repository"]["html_url"], title: search["repository"]["full_name"], domain: "github.com", metadata: {"github_analyzer" => search_metadata[:github_analyzer]})
        github_result.save!
        github_result.update_vulnerabilities(vulnerabilities)
        @results << github_result
      end
    end
  end

  def run
    # Store results in results array
    @results = []

    puts "Checking #{@terms.length.to_s} search terms on #{@search_scope.length.to_s} scopes"

    @search_scope.each do |scope, type|
      # For each scope (user, org, repo) check if the search terms match anything
      puts "Checking #{scope}"
      @retry_interval = 0
      @terms.each do |term|

        begin
          # If the scope is a repo, we need to set a different query string
          if type == "repo"
            response = RestClient.get URI.escape("https://api.github.com/search/code?q=#{term.strip}+in:#{@options[:scope]}+repo:#{scope}&access_token=#{@github_oauth_token}"), :accept => "application/vnd.github.v3.text-match+json"
          else
            response = RestClient.get URI.escape("https://api.github.com/search/code?q=#{term.strip}+in:#{@options[:scope]}+user:#{scope}&access_token=#{@github_oauth_token}"), :accept => "application/vnd.github.v3.text-match+json"
          end
        rescue RestClient::Exception => e
          Rails.logger.error e.message
          Rails.logger.error e.backtrace

          # If we hit an error, check rate limit before searching for the next term or scope
          begin
            if e.response.headers[:retry_after].present?
              retry_after(e.response.headers[:retry_after])
            else
              rate_limit_sleep(e.response.headers[:x_ratelimit_remaining], e.response.headers[:x_ratelimit_reset])
            end
          rescue => e
            puts "Could not retrieve response headers"
            create_event("Could not retrieve response headers", "Warn")
            next
          end

          if response.nil?
            @retry_interval = 0
            next
          end

          # Retry up to two times if we hit a retry_after exception or rate limit exception
          if @retry_interval > 2
            @retry_interval = 0
            next
          else
            @retry_interval += 1
            retry
          end
        rescue=>e
          create_event("Unknown error occurred\n\n. Exception: #{e.message}\n#{e.backtrace}", "Warn")
          next
        end

        json_response = JSON.parse(response)

        # If we have no findings, skip to the next search term
        if json_response["total_count"] == 0
          puts "no results for \'#{term}\'"
          rate_limit_sleep(response.headers[:x_ratelimit_remaining], response.headers[:x_ratelimit_reset])
          next
        end

        # If we have one page of results, parse them and go to the next term.
        if json_response["total_count"] <= 100
          # Sleep if we hit the rate limit
          parse_search(response, json_response, type)

          # Only return max results and truncate any extras
          if @results.length >= @options[:max_results]
            create_event("Hit maximum results limit\n\n. Exception: #{@options[:max_results].to_s}", "Warn")
            return []
          end
          rate_limit_sleep(response.headers[:x_ratelimit_remaining], response.headers[:x_ratelimit_reset])
          next
        end

        # I we have more than 100 results, need to get each page and parse
        if json_response["total_count"] >= 100
          # Parse out the first page of results
          parse_search(response, json_response, type)

          # Only return max results and truncate any extras (could be more efficient)
          if @results.length >= @options[:max_results]
            create_event("Hit maximum results limit\n\n. Exception: #{@options[:max_results].to_s}", "Warn")
            #return @results[0..@options[:max_results].to_i]
            return []
          end

          # Sleep if we hit the rate limit
          rate_limit_sleep(response.headers[:x_ratelimit_remaining], response.headers[:x_ratelimit_reset])

          # Grab total number of pages we need to scan
          unless response.headers[:link].split(" ")[0].split("=").last.gsub!(/\W/,'') == 0
            pages = response.headers[:link].split(" ")[2].split("=").last.gsub!(/\W/,'')
          end
          # Skip page 1 since we already parsed it, and parse every other page
          2.upto(pages.to_i) do | page |
            begin
              # If the scope is a repo, we need to set a different query string
              if type == "repo"
                response = RestClient.get URI.escape("https://api.github.com/search/code?q=#{term.strip}+in:#{@options[:scope]}+user:#{scope}&access_token=#{@github_oauth_token}&page=#{page}"), :accept => "application/vnd.github.v3.text-match+json"
              else
                response = RestClient.get URI.escape("https://api.github.com/search/code?q=#{term.strip}+in:#{@options[:scope]}+repo:#{scope}&access_token=#{@github_oauth_token}&page=#{page}"), :accept => "application/vnd.github.v3.text-match+json"
              end
            rescue RestClient::Exception => e
              begin
                if e.response.headers[:retry_after].present?
                  retry_after(e.response.headers[:retry_after])
                  retry
                else
                  rate_limit_sleep(e.response.headers[:x_ratelimit_remaining], e.response.headers[:x_ratelimit_reset])
                end
              rescue
                puts "Could not retrieve response headers"
                create_event("Could not retrieve response headers", "Warn")
                next
              end
            rescue=>e
              create_event("Unknown error occurred\n\n. Exception: #{e.message}\n#{e.backtrace}", "Warn")
              next
            end
            json_response = JSON.parse(response)
            # parse results for each page
            parse_search(response, json_response, type)

            # only return max results and truncate any extras (could be more efficient)
            if @results.length >= @options[:max_results]
              create_event("Hit maximum results limit\n\n. Exception: #{@options[:max_results].to_s}", "Warn")
              return []
            end
            rate_limit_sleep(response.headers[:x_ratelimit_remaining], response.headers[:x_ratelimit_reset])
          end
        end
      end
    end
    return []
  end
end
