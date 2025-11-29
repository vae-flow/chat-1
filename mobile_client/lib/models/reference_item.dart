class ReferenceItem {
  final String title;
  final String url;
  final String snippet;
  final String sourceName;

  ReferenceItem({
    required this.title,
    required this.url,
    required this.snippet,
    required this.sourceName,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'snippet': snippet,
        'sourceName': sourceName,
      };

  factory ReferenceItem.fromJson(Map<String, dynamic> json) {
    return ReferenceItem(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      snippet: json['snippet'] ?? '',
      sourceName: json['sourceName'] ?? '',
    );
  }
}
