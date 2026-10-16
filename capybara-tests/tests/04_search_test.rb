# frozen_string_literal: true

require_relative "../test_helper"

class SearchTest < ParityTest
  def setup
    sign_in_as!(:david)
  end

  def test_results_for_a_word_matching_two_rooms
    visit "/searches?q=coffee"
    assert_selector "#search-results .message", wait: 10
    assert_selector ".message", text: "Coffee machine is fixed!"
    assert_selector ".message", text: "Coffee first, then the launch plan."
    settled_snap("coffee")
  end

  def test_search_page_with_empty_query
    visit "/searches"
    assert_selector "form, input[name='q']", wait: 10
    settled_snap("empty")
  end

  def test_no_results_query
    visit "/searches?q=xyzzynotfound"
    settled_snap("no-results")
  end

  def test_recent_searches_are_listed
    visit "/searches"
    assert_selector ".searches a, .recent a, #searches *", text: "Borgias", visible: :all, wait: 10
    assert_selector ".searches a, .recent a, #searches *", text: "cuckoo", visible: :all
  end
end
