# An InnoDB index B-tree, given an Innodb::Space and a root page number.
class Innodb::Index
  attr_reader :root

  def initialize(space, root_page_number)
    @space = space
    @root = @space.page(root_page_number)

    unless @root
      raise "Page #{root_page_number} couldn't be read"
    end

    # The root page should be an index page.
    unless @root.type == :INDEX
      raise "Page #{root_page_number} is a #{@root.type} page, not an INDEX page"
    end

    # The root page should be the only page at its level.
    unless @root.prev.nil? && @root.next.nil?
      raise "Page #{root_page_number} is a node page, but not appear to be the root; it has previous page and next page pointers"
    end
  end

  # A helper function to access the index ID in the page header.
  def id
    @root.page_header[:index_id]
  end

  # Return the type of node that the given page represents in the index tree.
  def node_type(page)
    if @root.offset == page.offset
      :root
    elsif page.level == 0
      :leaf
    else
      :internal
    end
  end

  # Internal method used by recurse.
  def _recurse(parent_page, page_proc, link_proc, depth=0)
    if page_proc && parent_page.type == :INDEX
      page_proc.call(parent_page, depth)
    end

    parent_page.each_child_page do |child_page_number, child_min_key|
      child_page = @space.page(child_page_number)
      child_page.record_describer = @space.record_describer
      if child_page.type == :INDEX
        if link_proc
          link_proc.call(parent_page, child_page, child_min_key, depth+1)
        end
        _recurse(child_page, page_proc, link_proc, depth+1)
      end
    end
  end

  # Walk an index tree depth-first, calling procs for each page and link
  # in the tree.
  def recurse(page_proc, link_proc)
    _recurse(@root, page_proc, link_proc)
  end

  # Return the first leaf page in the index by walking down the left side
  # of the B-tree until a page at the given level is encountered.
  def first_page_at_level(level)
    page = @root
    record = @root.first_record
    while record && page.level > level
      page = @space.page(record[:child_page_number])
      record = page.first_record
    end
    page if page.level == level
  end

  # Iterate through all pages at this level starting with the provided page.
  def each_page_from(page)
    while page && page.type == :INDEX
      yield page
      page = @space.page(page.next)
    end
  end

  # Iterate through all pages at the given level by finding the first page
  # and following the next pointers in each page.
  def each_page_at_level(level)
    each_page_from(first_page_at_level(level)) { |page| yield page }
  end

  # Iterate through all records on all leaf pages in ascending order.
  def each_record
    each_page_at_level(0) do |page|
      page.each_record do |record|
        yield record
      end
    end
  end

  # Compare two arrays of fields to determine if they are equal. This follows
  # the same comparison rules as strcmp and others:
  #   0 = a is equal to b
  #   -1 = a is less than b
  #   +1 = a is greater than b
  def compare_key(a, b)
    return 0 if a.nil? && b.nil?
    return -1 if a.nil? || (!b.nil? && a.size < b.size)
    return +1 if b.nil? || (!a.nil? && a.size > b.size)

    a.each_index do |i|
      return -1 if a[i] < b[i]
      return +1 if a[i] > b[i]
    end

    return 0
  end

  # Search for a record within a single page, and return either a perfect
  # match for the key, or the last record closest to they key but not greater
  # than the key. (If an exact match is desired, compare_key must be used to
  # check if the returned record matches. This makes the function useful for
  # search in both leaf and non-leaf pages.)
  def linear_search_from_cursor(cursor, key)
    this_rec = cursor.record

    # Iterate through all records until finding either a matching record or
    # one whose key is greater than the desired key.
    while this_rec && next_rec = cursor.record
      # If we reach supremum, return the last non-system record we got.
      return this_rec if next_rec[:header][:type] == :supremum

      if (compare_key(key, this_rec[:key]) >= 0) &&
        (compare_key(key, next_rec[:key]) < 0)
        # The desired key is either an exact match for this_rec or is greater
        # than it but less than next_rec. If this is a non-leaf page, that
        # will mean that the record will fall on the leaf page this node
        # pointer record points to, if it exists at all.
        return this_rec
      end

      this_rec = next_rec
    end

    this_rec
  end

  # Search or a record within a single page using the page directory to limit
  # the number of record comparisons required. Once the last page directory
  # entry closest to but not greater than the key is found, fall back to
  # linear search using linear_search_from_cursor to find the closest record
  # whose key is not greater than the desired key. (If an exact match is
  # desired, the returned record must be checked in the same way as the above
  # linear_search_from_cursor function.)
  def binary_search_by_directory(page, dir, key)
    return nil if dir.empty?

    # Split the directory at the mid-point (using integer math, so the division
    # is rounding down). Retrieve the record that sits at the mid-point.
    mid = dir.size / 2
    rec = page.record(dir[mid])

    # The mid-point record was the infimum record, which is not comparable with
    # compare_key, so we need to just linear scan from here. If the mid-point
    # is the beginning of the page there can't be many records left to check
    # anyway.
    if rec[:header][:type] == :infimum
      return linear_search_from_cursor(page.record_cursor(rec[:next]), key)
    end

    # Compare the desired key to the mid-point record's key.
    case compare_key(key, rec[:key])
    when 0
      # An exact match for the key was found. Return the record.
      rec
    when +1
      # The mid-point record's key is less than the desired key.
      if dir.size == 1
        # This is the last entry remaining from the directory, use linear
        # search to find the record. We already know that there wasn't an
        # exact match, so skip the current record and start cursoring from
        # the next record.
        linear_search_from_cursor(page.record_cursor(rec[:next]), key)
      else
        # There are more entries remaining from the directory, recurse again
        # using binary search on the right half of the directory, which
        # represents values greater than or equal to the mid-point record's
        # key.
        binary_search_by_directory(page, dir[mid...dir.size], key)
      end
    when -1
      # The mid-point record's key is greater than the desired key.
      if dir.size == 1
        # If this is the last entry remaining from the directory, we didn't
        # find anything workable.
        nil
      else
        # Recurse on the left half of the directory, which represents values
        # less than the mid-point record's key.
        binary_search_by_directory(page, dir[0...mid], key)
      end
    end
  end

  # Search for a record within the entire index, walking down the non-leaf
  # pages until a leaf page is found, and then verifying that the record
  # returned on the leaf page is an exact match for the key. If a matching
  # record is not found, nil is returned (either because linear_search_in_page
  # returns nil breaking the loop, or because compare_key returns non-zero).
  def linear_search(key)
    page = @root

    while rec =
      linear_search_from_cursor(page.record_cursor(page.infimum[:next]), key)
      if page.level > 0
        # If we haven't reached a leaf page yet, move down the tree and search
        # again using linear search.
        page = @space.page(rec[:child_page_number])
      else
        # We're on a leaf page, so return the page and record if there is a
        # match. If there is no match, break the loop and cause nil to be
        # returned.
        return page, rec if compare_key(key, rec[:key]) == 0
        break
      end
    end
  end

  # Search for a record within the entire index like linear_search, but use
  # the page directory to search while making as few record comparisons as
  # possible. If a matching record is not found, nil is returned.
  def binary_search(key)
    page = @root

    while rec = binary_search_by_directory(page, page.directory.dup, key)
      if page.level > 0
        # If we haven't reached a leaf page yet, move down the tree and search
        # again using binary search.
        page = @space.page(rec[:child_page_number])
      else
        # We're on a leaf page, so return the page and record if there is a
        # match. If there is no match, break the loop and cause nil to be
        # returned.
        return page, rec if compare_key(key, rec[:key]) == 0
        break
      end
    end
  end

end
